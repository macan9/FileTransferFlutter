/*
 * Minimal Wintun-backed EthernetTap skeleton for the Flutter Windows host.
 *
 * This class currently owns the Wintun adapter control-plane only: it opens or
 * creates the adapter and exposes its LUID/ifIndex to libzt. Packet session I/O
 * is intentionally left for the next integration step.
 */

#ifndef ZT_WINTUNETHERNETTAP_HPP
#define ZT_WINTUNETHERNETTAP_HPP

#include <WinSock2.h>
#include <Windows.h>
#include <ifdef.h>
#include <netioapi.h>

#include <deque>
#include <string>
#include <vector>

#include "Arp.hpp"
#include "../node/Constants.hpp"
#include "../node/InetAddress.hpp"
#include "../node/MAC.hpp"
#include "../node/MulticastGroup.hpp"
#include "../node/Mutex.hpp"
#include "EthernetTap.hpp"

namespace ZeroTier {

class WintunEthernetTap : public EthernetTap
{
public:
	WintunEthernetTap(
		const char *homePath,
		const MAC &mac,
		unsigned int mtu,
		unsigned int metric,
		uint64_t nwid,
		const char *friendlyName,
		void (*handler)(void *,void *,uint64_t,const MAC &,const MAC &,unsigned int,unsigned int,const void *,unsigned int),
		void *arg);

	virtual ~WintunEthernetTap();

	virtual void setEnabled(bool en);
	virtual bool enabled() const;
	virtual bool addIp(const InetAddress &ip);
	virtual bool removeIp(const InetAddress &ip);
	virtual std::vector<InetAddress> ips() const;
	virtual void put(const MAC &from,const MAC &to,unsigned int etherType,const void *data,unsigned int len);
	virtual std::string deviceName() const;
	virtual void setFriendlyName(const char *friendlyName);
	virtual std::string friendlyName() const;
	virtual void scanMulticastGroups(std::vector<MulticastGroup> &added,std::vector<MulticastGroup> &removed);
	virtual void setMtu(unsigned int mtu);
	virtual void setDns(const char *domain,const std::vector<InetAddress> &servers);

	inline const NET_LUID &luid() const { return _adapterLuid; }
	NET_IFINDEX interfaceIndex() const;
	bool isInitialized() const { return _initialized; }

private:
	using WintunAdapterHandle = void *;
	using WintunSessionHandle = void *;
	using WintunCreateAdapterFn = WintunAdapterHandle (WINAPI *)(const wchar_t *,const wchar_t *,const GUID *);
	using WintunOpenAdapterFn = WintunAdapterHandle (WINAPI *)(const wchar_t *);
	using WintunCloseAdapterFn = void (WINAPI *)(WintunAdapterHandle);
	using WintunGetAdapterLuidFn = void (WINAPI *)(WintunAdapterHandle,NET_LUID *);
	using WintunStartSessionFn = WintunSessionHandle (WINAPI *)(WintunAdapterHandle,DWORD);
	using WintunEndSessionFn = void (WINAPI *)(WintunSessionHandle);
	using WintunGetReadWaitEventFn = HANDLE (WINAPI *)(WintunSessionHandle);
	using WintunReceivePacketFn = BYTE *(WINAPI *)(WintunSessionHandle,DWORD *);
	using WintunReleaseReceivePacketFn = void (WINAPI *)(WintunSessionHandle,const BYTE *);
	using WintunAllocateSendPacketFn = BYTE *(WINAPI *)(WintunSessionHandle,DWORD);
	using WintunSendPacketFn = void (WINAPI *)(WintunSessionHandle,const BYTE *);

	struct WintunApi
	{
		HMODULE module = nullptr;
		WintunCreateAdapterFn createAdapter = nullptr;
		WintunOpenAdapterFn openAdapter = nullptr;
		WintunCloseAdapterFn closeAdapter = nullptr;
		WintunGetAdapterLuidFn getAdapterLuid = nullptr;
		WintunStartSessionFn startSession = nullptr;
		WintunEndSessionFn endSession = nullptr;
		WintunGetReadWaitEventFn getReadWaitEvent = nullptr;
		WintunReceivePacketFn receivePacket = nullptr;
		WintunReleaseReceivePacketFn releaseReceivePacket = nullptr;
		WintunAllocateSendPacketFn allocateSendPacket = nullptr;
		WintunSendPacketFn sendPacket = nullptr;
		std::wstring loadedFrom;
	};

	static std::wstring defaultAdapterName();
	static std::wstring defaultTunnelType();
	static bool loadWintunApi(WintunApi &api,std::string &error);
	static bool bringInterfaceAdminUp(NET_IFINDEX ifIndex);

	void openOrCreateAdapter();
	void startSession();
	void stopSession();
	void closeAdapter();
	void receiveLoop();
	void handleInboundIpPacket(const BYTE *packet,DWORD packetSize);
	void handleInboundIpv4Packet(const BYTE *packet,DWORD packetSize);
	void handleInboundIpv6Packet(const BYTE *packet,DWORD packetSize);
	void handleIncomingArpFrame(const void *data,unsigned int len);
	void flushQueuedIpv4(uint32_t targetIp,const MAC &destination);
	void sendFrameToZeroTier(const MAC &to,unsigned int etherType,const void *data,unsigned int len);
	void enqueueIpv4(uint32_t targetIp,const BYTE *packet,DWORD packetSize);
	bool sendPacketToWintun(const void *data,unsigned int len);

	static DWORD WINAPI receiveThreadEntry(LPVOID context);

	struct PendingIpv4Packet
	{
		uint32_t targetIp = 0;
		unsigned int len = 0;
		unsigned char data[ZT_MAX_MTU] = { 0 };
	};

	WintunApi _api;
	WintunAdapterHandle _adapter = nullptr;
	WintunSessionHandle _session = nullptr;
	HANDLE _receiveThread = nullptr;
	HANDLE _stopEvent = nullptr;
	NET_LUID _adapterLuid = {};
	NET_IFINDEX _ifIndex = 0;
	std::wstring _adapterNameWide;
	std::string _adapterName;
	std::string _friendlyName;
	std::vector<InetAddress> _assignedIps;
	mutable Mutex _assignedIpsMutex;
	Arp _arp;
	Mutex _arpMutex;
	std::deque<PendingIpv4Packet> _pendingIpv4;
	Mutex _pendingIpv4Mutex;
	Mutex _sendMutex;
	volatile bool _initialized = false;
	volatile bool _enabled = true;
	volatile bool _sessionStarted = false;
	volatile unsigned long long _rxPackets = 0;
	volatile unsigned long long _rxBytes = 0;
	volatile unsigned long long _injectedPackets = 0;
	volatile unsigned long long _injectedBytes = 0;
	volatile unsigned long long _txPackets = 0;
	volatile unsigned long long _txBytes = 0;
	volatile unsigned long long _queuedPackets = 0;
	volatile unsigned long long _droppedPackets = 0;
	volatile unsigned int _mtu = 0;
	MAC _mac;
	uint64_t _nwid = 0;
	void (*_handler)(void *,void *,uint64_t,const MAC &,const MAC &,unsigned int,unsigned int,const void *,unsigned int) = nullptr;
	void *_arg = nullptr;
};

} // namespace ZeroTier

#endif
