#include "WintunEthernetTap.hpp"

#include <iphlpapi.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <sstream>
#include <stdexcept>

#include "OSUtils.hpp"

namespace ZeroTier {

namespace {

const unsigned int kEtherTypeIpv4 = 0x0800;
const unsigned int kEtherTypeArp = 0x0806;
const unsigned int kEtherTypeIpv6 = 0x86dd;
const size_t kMaxPendingIpv4Packets = 512;
const uint64_t kPendingIpv4RetryInterval = 1000;
const uint64_t kPendingIpv4MaxAge = 15000;
const uint64_t kStatsLogInterval = 10000;

std::string wideToUtf8(const std::wstring &value)
{
	if (value.empty()) {
		return std::string();
	}
	const int required = WideCharToMultiByte(CP_UTF8,0,value.c_str(),-1,nullptr,0,nullptr,nullptr);
	if (required <= 1) {
		return std::string();
	}
	std::string result(static_cast<size_t>(required),'\0');
	WideCharToMultiByte(CP_UTF8,0,value.c_str(),-1,&result[0],required,nullptr,nullptr);
	result.pop_back();
	return result;
}

std::wstring utf8ToWide(const char *value)
{
	if ((!value)||(!*value)) {
		return std::wstring();
	}
	const int required = MultiByteToWideChar(CP_UTF8,0,value,-1,nullptr,0);
	if (required <= 1) {
		return std::wstring();
	}
	std::wstring result(static_cast<size_t>(required),L'\0');
	MultiByteToWideChar(CP_UTF8,0,value,-1,&result[0],required);
	result.pop_back();
	return result;
}

std::wstring currentExecutableDirectory()
{
	std::wstring buffer(MAX_PATH,L'\0');
	while (true) {
		const DWORD length = GetModuleFileNameW(nullptr,&buffer[0],static_cast<DWORD>(buffer.size()));
		if (length == 0) {
			return std::wstring();
		}
		if (length < buffer.size() - 1) {
			buffer.resize(length);
			const size_t slash = buffer.find_last_of(L"\\/");
			if (slash == std::wstring::npos) {
				return std::wstring();
			}
			return buffer.substr(0,slash);
		}
		buffer.resize(buffer.size() * 2);
	}
}

std::wstring joinPath(const std::wstring &base,const std::wstring &leaf)
{
	if (base.empty()) {
		return leaf;
	}
	if (base[base.size() - 1] == L'\\' || base[base.size() - 1] == L'/') {
		return base + leaf;
	}
	return base + L"\\" + leaf;
}

void addCandidate(std::vector<std::wstring> &candidates,const std::wstring &path)
{
	if (path.empty()) {
		return;
	}
	if (std::find(candidates.begin(),candidates.end(),path) == candidates.end()) {
		candidates.push_back(path);
	}
}

bool hasDllFileName(const std::wstring &path)
{
	const size_t slash = path.find_last_of(L"\\/");
	const std::wstring fileName = slash == std::wstring::npos ? path : path.substr(slash + 1);
	return _wcsicmp(fileName.c_str(),L"wintun.dll") == 0;
}

std::vector<std::wstring> buildWintunDllCandidates()
{
	std::vector<std::wstring> candidates;
	char *envValue = nullptr;
	size_t envSize = 0;
	if ((_dupenv_s(&envValue,&envSize,"ZT_WINTUN_DLL") == 0)&&(envValue != nullptr)) {
		const std::wstring configured = utf8ToWide(envValue);
		free(envValue);
		if (!configured.empty()) {
			if (hasDllFileName(configured)) {
				addCandidate(candidates,configured);
			}
			else {
				addCandidate(candidates,joinPath(configured,L"wintun.dll"));
			}
		}
	}
	const std::wstring exeDir = currentExecutableDirectory();
	addCandidate(candidates,joinPath(exeDir,L"wintun.dll"));
	addCandidate(candidates,joinPath(joinPath(exeDir,L"lib"),L"wintun.dll"));
	addCandidate(candidates,joinPath(joinPath(exeDir,L"bin"),L"wintun.dll"));
	addCandidate(candidates,L"wintun.dll");
	return candidates;
}

bool isIpv4BroadcastOrLimitedBroadcast(uint32_t ip)
{
	return ip == 0xffffffffU;
}

bool isIpv4Multicast(uint32_t ip)
{
	const uint32_t hostOrder = ntohl(ip);
	return (hostOrder & 0xf0000000U) == 0xe0000000U;
}

MAC ipv4MulticastToMac(uint32_t ip)
{
	const uint32_t hostOrder = ntohl(ip);
	return MAC(
		0x01,
		0x00,
		0x5e,
		static_cast<unsigned char>((hostOrder >> 16) & 0x7f),
		static_cast<unsigned char>((hostOrder >> 8) & 0xff),
		static_cast<unsigned char>(hostOrder & 0xff));
}

bool isIpv6Multicast(const BYTE *packet,DWORD packetSize)
{
	return packetSize >= 40 && packet[24] == 0xff;
}

MAC ipv6MulticastToMac(const BYTE *packet)
{
	return MAC(0x33,0x33,packet[36],packet[37],packet[38],packet[39]);
}

std::string ipv4ToString(uint32_t ip)
{
	char buffer[INET_ADDRSTRLEN] = { 0 };
	in_addr address;
	address.s_addr = ip;
	if (InetNtopA(AF_INET,&address,buffer,sizeof(buffer)) == nullptr) {
		return std::string("0.0.0.0");
	}
	return std::string(buffer);
}

} // namespace

std::wstring WintunEthernetTap::defaultAdapterName(uint64_t nwid)
{
	char *envValue = nullptr;
	size_t envSize = 0;
	if ((_dupenv_s(&envValue,&envSize,"ZT_WINTUN_ADAPTER_NAME") == 0)&&(envValue != nullptr)) {
		const std::wstring configured = utf8ToWide(envValue);
		free(envValue);
		if (!configured.empty()) {
			return configured;
		}
	}
	std::wstringstream stream;
	stream << L"FileTransferFlutter-" << std::hex << std::nouppercase << nwid;
	return stream.str();
}

std::wstring WintunEthernetTap::defaultTunnelType()
{
	char *envValue = nullptr;
	size_t envSize = 0;
	if ((_dupenv_s(&envValue,&envSize,"ZT_WINTUN_TUNNEL_TYPE") == 0)&&(envValue != nullptr)) {
		const std::wstring configured = utf8ToWide(envValue);
		free(envValue);
		if (!configured.empty()) {
			return configured;
		}
	}
	return L"FileTransferFlutter";
}

GUID WintunEthernetTap::adapterGuid(uint64_t nwid)
{
	GUID guid = { 0x9f0f6f21, 0x2a6b, 0x4bbf, { 0xb9, 0x30, 0x7a, 0xe2, 0x63, 0x85, 0x5d, 0x11 } };
	guid.Data1 ^= static_cast<unsigned long>(nwid & 0xffffffffULL);
	guid.Data2 ^= static_cast<unsigned short>((nwid >> 32) & 0xffffULL);
	guid.Data3 ^= static_cast<unsigned short>((nwid >> 48) & 0xffffULL);
	for (int i = 0; i < 8; ++i) {
		guid.Data4[i] ^= static_cast<unsigned char>((nwid >> ((i % 8) * 8)) & 0xffULL);
	}
	return guid;
}

bool WintunEthernetTap::loadWintunApi(WintunApi &api,std::string &error)
{
	for (const auto &candidate : buildWintunDllCandidates()) {
		api.module = LoadLibraryW(candidate.c_str());
		if (api.module != nullptr) {
			api.loadedFrom = candidate;
			break;
		}
	}
	if (api.module == nullptr) {
		error = "wintun.dll not found";
		return false;
	}
	api.createAdapter = reinterpret_cast<WintunCreateAdapterFn>(GetProcAddress(api.module,"WintunCreateAdapter"));
	api.openAdapter = reinterpret_cast<WintunOpenAdapterFn>(GetProcAddress(api.module,"WintunOpenAdapter"));
	api.closeAdapter = reinterpret_cast<WintunCloseAdapterFn>(GetProcAddress(api.module,"WintunCloseAdapter"));
	api.getAdapterLuid = reinterpret_cast<WintunGetAdapterLuidFn>(GetProcAddress(api.module,"WintunGetAdapterLUID"));
	api.startSession = reinterpret_cast<WintunStartSessionFn>(GetProcAddress(api.module,"WintunStartSession"));
	api.endSession = reinterpret_cast<WintunEndSessionFn>(GetProcAddress(api.module,"WintunEndSession"));
	api.getReadWaitEvent = reinterpret_cast<WintunGetReadWaitEventFn>(GetProcAddress(api.module,"WintunGetReadWaitEvent"));
	api.receivePacket = reinterpret_cast<WintunReceivePacketFn>(GetProcAddress(api.module,"WintunReceivePacket"));
	api.releaseReceivePacket = reinterpret_cast<WintunReleaseReceivePacketFn>(GetProcAddress(api.module,"WintunReleaseReceivePacket"));
	api.allocateSendPacket = reinterpret_cast<WintunAllocateSendPacketFn>(GetProcAddress(api.module,"WintunAllocateSendPacket"));
	api.sendPacket = reinterpret_cast<WintunSendPacketFn>(GetProcAddress(api.module,"WintunSendPacket"));
	if ((!api.createAdapter)||(!api.openAdapter)||(!api.closeAdapter)||(!api.getAdapterLuid)||
		(!api.startSession)||(!api.endSession)||(!api.getReadWaitEvent)||(!api.receivePacket)||(!api.releaseReceivePacket)||
		(!api.allocateSendPacket)||(!api.sendPacket)) {
		error = "wintun.dll missing required adapter exports";
		return false;
	}
	return true;
}

bool WintunEthernetTap::bringInterfaceAdminUp(NET_IFINDEX ifIndex)
{
	if (ifIndex == 0) {
		return false;
	}
	MIB_IFROW row;
	memset(&row,0,sizeof(row));
	row.dwIndex = ifIndex;
	if (GetIfEntry(&row) != NO_ERROR) {
		return false;
	}
	if (row.dwAdminStatus == MIB_IF_ADMIN_STATUS_UP) {
		return true;
	}
	row.dwAdminStatus = MIB_IF_ADMIN_STATUS_UP;
	return SetIfEntry(&row) == NO_ERROR;
}

WintunEthernetTap::WintunEthernetTap(
	const char *homePath,
	const MAC &mac,
	unsigned int mtu,
	unsigned int metric,
	uint64_t nwid,
	const char *friendlyName,
	void (*handler)(void *,void *,uint64_t,const MAC &,const MAC &,unsigned int,unsigned int,const void *,unsigned int),
	void *arg)
	: _adapterNameWide(defaultAdapterName(nwid))
	, _adapterName(wideToUtf8(_adapterNameWide))
	, _friendlyName((friendlyName && *friendlyName) ? friendlyName : _adapterName)
	, _mtu(mtu)
	, _mac(mac)
	, _nwid(nwid)
	, _handler(handler)
	, _arg(arg)
{
	(void)homePath;
	(void)metric;
	openOrCreateAdapter();
	startSession();
}

WintunEthernetTap::~WintunEthernetTap()
{
	stopSession();
	closeAdapter();
}

void WintunEthernetTap::openOrCreateAdapter()
{
	std::string loadError;
	if (!loadWintunApi(_api,loadError)) {
		throw std::runtime_error("WintunEthernetTap: " + loadError);
	}

	_adapter = _api.openAdapter(_adapterNameWide.c_str());
	if (_adapter == nullptr) {
		const GUID requestedGuid = adapterGuid(_nwid);
		_adapter = _api.createAdapter(_adapterNameWide.c_str(),defaultTunnelType().c_str(),&requestedGuid);
	}
	if (_adapter == nullptr) {
		std::ostringstream stream;
		stream << "WintunEthernetTap: open/create adapter failed error=" << GetLastError();
		throw std::runtime_error(stream.str());
	}

	memset(&_adapterLuid,0,sizeof(_adapterLuid));
	_api.getAdapterLuid(_adapter,&_adapterLuid);
	if (ConvertInterfaceLuidToIndex(&_adapterLuid,&_ifIndex) != NO_ERROR || _ifIndex == 0) {
		std::ostringstream stream;
		stream << "WintunEthernetTap: ConvertInterfaceLuidToIndex failed error=" << GetLastError();
		throw std::runtime_error(stream.str());
	}
	bringInterfaceAdminUp(_ifIndex);
	_initialized = true;

	fprintf(stderr,"[ZT/WINTUN] adapter_ready name=%s ifIndex=%lu luid=%llu dll=%s\n",
		_adapterName.c_str(),
		static_cast<unsigned long>(_ifIndex),
		static_cast<unsigned long long>(_adapterLuid.Value),
		wideToUtf8(_api.loadedFrom).c_str());
}

void WintunEthernetTap::startSession()
{
	if (_session != nullptr) {
		return;
	}
	_stopEvent = CreateEventW(nullptr,TRUE,FALSE,nullptr);
	if (_stopEvent == nullptr) {
		throw std::runtime_error("WintunEthernetTap: CreateEvent failed");
	}

	const DWORD ringCapacity = 0x400000;
	_session = _api.startSession(_adapter,ringCapacity);
	if (_session == nullptr) {
		const DWORD error = GetLastError();
		CloseHandle(_stopEvent);
		_stopEvent = nullptr;
		std::ostringstream stream;
		stream << "WintunEthernetTap: WintunStartSession failed error=" << error;
		throw std::runtime_error(stream.str());
	}

	_receiveThread = CreateThread(nullptr,0,&WintunEthernetTap::receiveThreadEntry,this,0,nullptr);
	if (_receiveThread == nullptr) {
		const DWORD error = GetLastError();
		_api.endSession(_session);
		_session = nullptr;
		CloseHandle(_stopEvent);
		_stopEvent = nullptr;
		std::ostringstream stream;
		stream << "WintunEthernetTap: CreateThread failed error=" << error;
		throw std::runtime_error(stream.str());
	}
	_sessionStarted = true;
	fprintf(stderr,"[ZT/WINTUN] session_started name=%s ifIndex=%lu capacity=%lu\n",
		_adapterName.c_str(),
		static_cast<unsigned long>(_ifIndex),
		static_cast<unsigned long>(ringCapacity));
}

void WintunEthernetTap::stopSession()
{
	_sessionStarted = false;
	if (_stopEvent != nullptr) {
		SetEvent(_stopEvent);
	}
	if (_receiveThread != nullptr) {
		WaitForSingleObject(_receiveThread,5000);
		CloseHandle(_receiveThread);
		_receiveThread = nullptr;
	}
	if ((_api.endSession != nullptr)&&(_session != nullptr)) {
		_api.endSession(_session);
		_session = nullptr;
	}
	if (_stopEvent != nullptr) {
		CloseHandle(_stopEvent);
		_stopEvent = nullptr;
	}
	fprintf(stderr,"[ZT/WINTUN] session_stopped name=%s ifIndex=%lu rx_packets=%llu rx_bytes=%llu\n",
		_adapterName.c_str(),
		static_cast<unsigned long>(_ifIndex),
		static_cast<unsigned long long>(_rxPackets),
		static_cast<unsigned long long>(_rxBytes));
	fprintf(stderr,"[ZT/WINTUN] dataplane_stats injected_packets=%llu injected_bytes=%llu queued_packets=%llu flushed_packets=%llu arp_queries_sent=%llu arp_replies_received=%llu arp_responses_sent=%llu dropped_packets=%llu\n",
		static_cast<unsigned long long>(_injectedPackets),
		static_cast<unsigned long long>(_injectedBytes),
		static_cast<unsigned long long>(_queuedPackets),
		static_cast<unsigned long long>(_flushedPackets),
		static_cast<unsigned long long>(_arpQueriesSent),
		static_cast<unsigned long long>(_arpRepliesReceived),
		static_cast<unsigned long long>(_arpResponsesSent),
		static_cast<unsigned long long>(_droppedPackets));
	fprintf(stderr,"[ZT/WINTUN] wintun_tx_stats tx_packets=%llu tx_bytes=%llu\n",
		static_cast<unsigned long long>(_txPackets),
		static_cast<unsigned long long>(_txBytes));
	maybeLogStats(true);
}

void WintunEthernetTap::closeAdapter()
{
	_initialized = false;
	if ((_api.closeAdapter != nullptr)&&(_adapter != nullptr)) {
		_api.closeAdapter(_adapter);
		_adapter = nullptr;
	}
	if (_api.module != nullptr) {
		FreeLibrary(_api.module);
		_api = WintunApi();
	}
}

DWORD WINAPI WintunEthernetTap::receiveThreadEntry(LPVOID context)
{
	reinterpret_cast<WintunEthernetTap *>(context)->receiveLoop();
	return 0;
}

void WintunEthernetTap::receiveLoop()
{
	HANDLE readWaitEvent = _api.getReadWaitEvent(_session);
	HANDLE waitHandles[2] = { _stopEvent, readWaitEvent };
	while ((_sessionStarted)&&(_session != nullptr)) {
		DWORD packetSize = 0;
		BYTE *packet = _api.receivePacket(_session,&packetSize);
		if (packet != nullptr) {
			++_rxPackets;
			_rxBytes += packetSize;
			handleInboundIpPacket(packet,packetSize);
			_api.releaseReceivePacket(_session,packet);
			processPendingIpv4Resolutions();
			maybeLogStats(false);
			continue;
		}
		const DWORD error = GetLastError();
		if (error == ERROR_NO_MORE_ITEMS) {
			processPendingIpv4Resolutions();
			maybeLogStats(false);
			const DWORD waitResult = WaitForMultipleObjects(2,waitHandles,FALSE,250);
			if (waitResult == WAIT_OBJECT_0) {
				break;
			}
			continue;
		}
		if (error == ERROR_HANDLE_EOF) {
			break;
		}
		Sleep(50);
	}
}

void WintunEthernetTap::handleInboundIpPacket(const BYTE *packet,DWORD packetSize)
{
	if ((!packet)||(packetSize == 0)||(!_enabled)) {
		if (!_enabled) {
			++_dropDisabledPackets;
			++_droppedPackets;
		}
		return;
	}
	const unsigned int version = (packet[0] >> 4) & 0x0f;
	if (version == 4) {
		handleInboundIpv4Packet(packet,packetSize);
	}
	else if (version == 6) {
		handleInboundIpv6Packet(packet,packetSize);
	}
	else {
		++_dropInvalidPackets;
		++_droppedPackets;
	}
}

void WintunEthernetTap::handleInboundIpv4Packet(const BYTE *packet,DWORD packetSize)
{
	if (packetSize < 20) {
		++_dropInvalidPackets;
		++_droppedPackets;
		return;
	}
	const unsigned int headerLen = static_cast<unsigned int>(packet[0] & 0x0f) * 4;
	if (headerLen < 20 || packetSize < headerLen) {
		++_dropInvalidPackets;
		++_droppedPackets;
		return;
	}
	if (packetSize > ZT_MAX_MTU) {
		++_dropInvalidPackets;
		++_droppedPackets;
		return;
	}

	uint32_t sourceIp = 0;
	uint32_t targetIp = 0;
	memcpy(&sourceIp,packet + 12,4);
	memcpy(&targetIp,packet + 16,4);

	if (isIpv4BroadcastOrLimitedBroadcast(targetIp) || isAssignedIpv4Broadcast(targetIp)) {
		sendFrameToZeroTier(MAC(0xffffffffffffULL),kEtherTypeIpv4,packet,packetSize);
		return;
	}
	if (isIpv4Multicast(targetIp)) {
		sendFrameToZeroTier(ipv4MulticastToMac(targetIp),kEtherTypeIpv4,packet,packetSize);
		return;
	}

	unsigned char query[ZT_ARP_BUF_LENGTH] = { 0 };
	unsigned int queryLen = 0;
	MAC queryDest;
	MAC targetMac;
	{
		Mutex::Lock lock(_arpMutex);
		targetMac = _arp.query(_mac,sourceIp,targetIp,query,queryLen,queryDest);
	}
	if (queryLen > 0) {
		sendFrameToZeroTier(queryDest,kEtherTypeArp,query,queryLen);
		++_arpQueriesSent;
	}
	if (targetMac) {
		sendFrameToZeroTier(targetMac,kEtherTypeIpv4,packet,packetSize);
	}
	else {
		enqueueIpv4(sourceIp,targetIp,packet,packetSize);
	}
}

void WintunEthernetTap::handleInboundIpv6Packet(const BYTE *packet,DWORD packetSize)
{
	if (packetSize < 40 || packetSize > ZT_MAX_MTU) {
		++_dropInvalidPackets;
		++_droppedPackets;
		return;
	}
	if (isIpv6Multicast(packet,packetSize)) {
		sendFrameToZeroTier(ipv6MulticastToMac(packet),kEtherTypeIpv6,packet,packetSize);
		return;
	}
	// IPv6 unicast requires a Wintun L3 to ZeroTier L2 neighbor-discovery
	// resolver. Keep this explicit until the ND queue is wired like IPv4 ARP.
	++_dropUnsupportedPackets;
	++_droppedPackets;
}

void WintunEthernetTap::handleIncomingArpFrame(const void *data,unsigned int len)
{
	unsigned char response[ZT_ARP_BUF_LENGTH] = { 0 };
	unsigned int responseLen = 0;
	MAC responseDest;
	uint32_t learnedIp = 0;
	{
		Mutex::Lock lock(_arpMutex);
		learnedIp = _arp.processIncomingArp(data,len,response,responseLen,responseDest);
	}
	if (responseLen > 0) {
		sendFrameToZeroTier(responseDest,kEtherTypeArp,response,responseLen);
		++_arpResponsesSent;
	}
	if (learnedIp != 0) {
		++_arpRepliesReceived;
		MAC targetMac;
		unsigned char ignoredQuery[ZT_ARP_BUF_LENGTH] = { 0 };
		unsigned int ignoredQueryLen = 0;
		MAC ignoredQueryDest;
		{
			Mutex::Lock lock(_arpMutex);
			targetMac = _arp.query(_mac,0,learnedIp,ignoredQuery,ignoredQueryLen,ignoredQueryDest);
		}
		if (targetMac) {
			char macString[18] = { 0 };
			targetMac.toString(macString);
			fprintf(stderr,"[ZT/WINTUN] arp_learned target=%s mac=%s peer=%010llx\n",
				ipv4ToString(learnedIp).c_str(),
				macString,
				static_cast<unsigned long long>(targetMac.toAddress(_nwid).toInt()));
			flushQueuedIpv4(learnedIp,targetMac);
		}
	}
}

bool WintunEthernetTap::isAssignedIpv4Broadcast(uint32_t ip) const
{
	Mutex::Lock lock(_assignedIpsMutex);
	for (std::vector<InetAddress>::const_iterator it = _assignedIps.begin(); it != _assignedIps.end(); ++it) {
		if ((!it->isV4())||(!it->netmaskBitsValid())) {
			continue;
		}
		const InetAddress broadcast = it->broadcast();
		if (!broadcast.isV4()) {
			continue;
		}
		uint32_t broadcastIp = 0;
		memcpy(&broadcastIp,broadcast.rawIpData(),4);
		if (broadcastIp == ip) {
			return true;
		}
	}
	return false;
}

void WintunEthernetTap::flushQueuedIpv4(uint32_t targetIp,const MAC &destination)
{
	std::deque<PendingIpv4Packet> ready;
	{
		Mutex::Lock lock(_pendingIpv4Mutex);
		for (std::deque<PendingIpv4Packet>::iterator it = _pendingIpv4.begin(); it != _pendingIpv4.end();) {
			if (it->targetIp == targetIp) {
				ready.push_back(*it);
				it = _pendingIpv4.erase(it);
			}
			else {
				++it;
			}
		}
	}
	for (std::deque<PendingIpv4Packet>::const_iterator it = ready.begin(); it != ready.end(); ++it) {
		sendFrameToZeroTier(destination,kEtherTypeIpv4,it->data,it->len);
		++_flushedPackets;
	}
	if (!ready.empty()) {
		fprintf(stderr,"[ZT/WINTUN] arp_resolved target=%s flushed=%llu\n",
			ipv4ToString(targetIp).c_str(),
			static_cast<unsigned long long>(ready.size()));
	}
}

void WintunEthernetTap::sendFrameToZeroTier(const MAC &to,unsigned int etherType,const void *data,unsigned int len)
{
	if ((!_handler)||(!data)||(len == 0)||(!_enabled)) {
		if (!_enabled) {
			++_dropDisabledPackets;
		}
		else {
			++_dropInvalidPackets;
		}
		++_droppedPackets;
		return;
	}
	_handler(_arg,(void *)0,_nwid,_mac,to,etherType,0,data,len);
	++_injectedPackets;
	_injectedBytes += len;
}

bool WintunEthernetTap::sendPacketToWintun(const void *data,unsigned int len)
{
	if ((!data)||(len == 0)||(len > 0xffff)) {
		++_dropInvalidPackets;
		++_droppedPackets;
		return false;
	}
	if (!_enabled) {
		++_dropDisabledPackets;
		++_droppedPackets;
		return false;
	}
	if ((!_sessionStarted)||(_session == nullptr)) {
		++_dropNoSessionPackets;
		++_droppedPackets;
		return false;
	}
	Mutex::Lock lock(_sendMutex);
	BYTE *packet = _api.allocateSendPacket(_session,static_cast<DWORD>(len));
	if (packet == nullptr) {
		++_dropSendAllocPackets;
		++_droppedPackets;
		return false;
	}
	memcpy(packet,data,len);
	_api.sendPacket(_session,packet);
	++_txPackets;
	_txBytes += len;
	return true;
}

void WintunEthernetTap::enqueueIpv4(uint32_t sourceIp,uint32_t targetIp,const BYTE *packet,DWORD packetSize)
{
	if ((!packet)||(packetSize == 0)||(packetSize > ZT_MAX_MTU)) {
		++_dropInvalidPackets;
		++_droppedPackets;
		return;
	}
	PendingIpv4Packet pending;
	pending.firstQueuedAt = OSUtils::now();
	pending.lastQueryAt = 0;
	pending.targetIp = targetIp;
	pending.sourceIp = sourceIp;
	pending.len = static_cast<unsigned int>(packetSize);
	memcpy(pending.data,packet,packetSize);
	{
		Mutex::Lock lock(_pendingIpv4Mutex);
		if (_pendingIpv4.size() >= kMaxPendingIpv4Packets) {
			_pendingIpv4.pop_front();
			++_dropQueueOverflowPackets;
			++_droppedPackets;
		}
		_pendingIpv4.push_back(pending);
	}
	++_queuedPackets;
}

void WintunEthernetTap::sendArpQuery(uint32_t sourceIp,uint32_t targetIp)
{
	unsigned char query[ZT_ARP_BUF_LENGTH] = { 0 };
	unsigned int queryLen = 0;
	MAC queryDest;
	{
		Mutex::Lock lock(_arpMutex);
		_arp.query(_mac,sourceIp,targetIp,query,queryLen,queryDest);
	}
	if (queryLen > 0) {
		sendFrameToZeroTier(queryDest,kEtherTypeArp,query,queryLen);
		++_arpQueriesSent;
	}
}

void WintunEthernetTap::processPendingIpv4Resolutions()
{
	struct Retry
	{
		uint32_t sourceIp;
		uint32_t targetIp;
	};
	std::vector<Retry> retries;
	const uint64_t now = OSUtils::now();
	{
		Mutex::Lock lock(_pendingIpv4Mutex);
		for (std::deque<PendingIpv4Packet>::iterator it = _pendingIpv4.begin(); it != _pendingIpv4.end();) {
			if ((it->firstQueuedAt == 0)||(now < it->firstQueuedAt)) {
				it->firstQueuedAt = now;
			}
			const uint64_t age = now - it->firstQueuedAt;
			if (age >= kPendingIpv4MaxAge) {
				fprintf(stderr,"[ZT/WINTUN] arp_pending_timeout target=%s age_ms=%llu retries=%u len=%u\n",
					ipv4ToString(it->targetIp).c_str(),
					static_cast<unsigned long long>(age),
					it->retries,
					it->len);
				it = _pendingIpv4.erase(it);
				++_dropQueueTimeoutPackets;
				++_droppedPackets;
				continue;
			}
			if ((it->lastQueryAt == 0)||((now - it->lastQueryAt) >= kPendingIpv4RetryInterval)) {
				Retry retry;
				retry.sourceIp = it->sourceIp;
				retry.targetIp = it->targetIp;
				retries.push_back(retry);
				it->lastQueryAt = now;
				++it->retries;
			}
			++it;
		}
	}
	for (std::vector<Retry>::const_iterator it = retries.begin(); it != retries.end(); ++it) {
		sendArpQuery(it->sourceIp,it->targetIp);
	}
}

void WintunEthernetTap::maybeLogStats(bool force)
{
	const uint64_t now = OSUtils::now();
	if ((!force)&&(_lastStatsLogAt != 0)&&((now - _lastStatsLogAt) < kStatsLogInterval)) {
		return;
	}
	_lastStatsLogAt = now;
	size_t pendingCount = 0;
	{
		Mutex::Lock lock(_pendingIpv4Mutex);
		pendingCount = _pendingIpv4.size();
	}
	fprintf(stderr,
		"[ZT/WINTUN] stats rx=%llu/%llu injected=%llu/%llu tx=%llu/%llu queued=%llu pending=%llu flushed=%llu arp_query=%llu arp_reply=%llu arp_resp=%llu drops=%llu invalid=%llu disabled=%llu overflow=%llu timeout=%llu no_session=%llu send_alloc=%llu unsupported=%llu\n",
		static_cast<unsigned long long>(_rxPackets),
		static_cast<unsigned long long>(_rxBytes),
		static_cast<unsigned long long>(_injectedPackets),
		static_cast<unsigned long long>(_injectedBytes),
		static_cast<unsigned long long>(_txPackets),
		static_cast<unsigned long long>(_txBytes),
		static_cast<unsigned long long>(_queuedPackets),
		static_cast<unsigned long long>(pendingCount),
		static_cast<unsigned long long>(_flushedPackets),
		static_cast<unsigned long long>(_arpQueriesSent),
		static_cast<unsigned long long>(_arpRepliesReceived),
		static_cast<unsigned long long>(_arpResponsesSent),
		static_cast<unsigned long long>(_droppedPackets),
		static_cast<unsigned long long>(_dropInvalidPackets),
		static_cast<unsigned long long>(_dropDisabledPackets),
		static_cast<unsigned long long>(_dropQueueOverflowPackets),
		static_cast<unsigned long long>(_dropQueueTimeoutPackets),
		static_cast<unsigned long long>(_dropNoSessionPackets),
		static_cast<unsigned long long>(_dropSendAllocPackets),
		static_cast<unsigned long long>(_dropUnsupportedPackets));
}

void WintunEthernetTap::setEnabled(bool en)
{
	_enabled = en;
}

bool WintunEthernetTap::enabled() const
{
	return _enabled;
}

bool WintunEthernetTap::addIp(const InetAddress &ip)
{
	Mutex::Lock lock(_assignedIpsMutex);
	if (std::find(_assignedIps.begin(),_assignedIps.end(),ip) == _assignedIps.end()) {
		_assignedIps.push_back(ip);
		std::sort(_assignedIps.begin(),_assignedIps.end());
	}
	if (ip.isV4()) {
		uint32_t localIp = 0;
		memcpy(&localIp,ip.rawIpData(),4);
		Mutex::Lock lockArp(_arpMutex);
		_arp.addLocal(localIp,_mac);
	}
	return true;
}

bool WintunEthernetTap::removeIp(const InetAddress &ip)
{
	Mutex::Lock lock(_assignedIpsMutex);
	std::vector<InetAddress>::iterator it = std::find(_assignedIps.begin(),_assignedIps.end(),ip);
	if (it != _assignedIps.end()) {
		_assignedIps.erase(it);
	}
	if (ip.isV4()) {
		uint32_t localIp = 0;
		memcpy(&localIp,ip.rawIpData(),4);
		Mutex::Lock lockArp(_arpMutex);
		_arp.remove(localIp);
	}
	return true;
}

std::vector<InetAddress> WintunEthernetTap::ips() const
{
	Mutex::Lock lock(_assignedIpsMutex);
	return _assignedIps;
}

void WintunEthernetTap::put(const MAC &from,const MAC &to,unsigned int etherType,const void *data,unsigned int len)
{
	(void)from;
	(void)to;
	if ((!data)||(len == 0)) {
		return;
	}
	if (etherType == kEtherTypeArp) {
		handleIncomingArpFrame(data,len);
		return;
	}
	if (etherType == kEtherTypeIpv4 || etherType == kEtherTypeIpv6) {
		sendPacketToWintun(data,len);
		return;
	}
	++_droppedPackets;
}

std::string WintunEthernetTap::deviceName() const
{
	return _adapterName;
}

void WintunEthernetTap::setFriendlyName(const char *friendlyName)
{
	_friendlyName = (friendlyName && *friendlyName) ? friendlyName : _adapterName;
}

std::string WintunEthernetTap::friendlyName() const
{
	return _friendlyName.empty() ? _adapterName : _friendlyName;
}

void WintunEthernetTap::scanMulticastGroups(std::vector<MulticastGroup> &added,std::vector<MulticastGroup> &removed)
{
	std::vector<MulticastGroup> nextGroups;
	{
		Mutex::Lock lock(_assignedIpsMutex);
		for (std::vector<InetAddress>::const_iterator ip = _assignedIps.begin(); ip != _assignedIps.end(); ++ip) {
			nextGroups.push_back(MulticastGroup::deriveMulticastGroupForAddressResolution(*ip));
		}
	}
	std::sort(nextGroups.begin(),nextGroups.end());
	nextGroups.erase(std::unique(nextGroups.begin(),nextGroups.end()),nextGroups.end());

	Mutex::Lock lock(_multicastGroupsMutex);
	for (std::vector<MulticastGroup>::const_iterator group = nextGroups.begin(); group != nextGroups.end(); ++group) {
		if (!std::binary_search(_multicastGroups.begin(),_multicastGroups.end(),*group)) {
			added.push_back(*group);
		}
	}
	for (std::vector<MulticastGroup>::const_iterator group = _multicastGroups.begin(); group != _multicastGroups.end(); ++group) {
		if (!std::binary_search(nextGroups.begin(),nextGroups.end(),*group)) {
			removed.push_back(*group);
		}
	}
	_multicastGroups.swap(nextGroups);
}

void WintunEthernetTap::setMtu(unsigned int mtu)
{
	_mtu = mtu;
}

void WintunEthernetTap::setDns(const char *domain,const std::vector<InetAddress> &servers)
{
	(void)domain;
	(void)servers;
}

NET_IFINDEX WintunEthernetTap::interfaceIndex() const
{
	return _ifIndex;
}

} // namespace ZeroTier
