// Integration probe: reads the same legacy GetControllerState API as old games.
// Run with SteamVR's bin/win64/openvr_api.dll path and duration in seconds.
// Background mode does not take over the game. SteamVR may mask its input.
// Optional third argument --scene obtains input focus for a dedicated test;
// this takes over VR and must not be used while playing a game.
#define NOMINMAX
#include <windows.h>
#include <openvr.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>

int wmain(int argc, wchar_t **argv) {
	if(argc<2) return 2;
	HMODULE api=LoadLibraryW(argv[1]);
	if(!api) { std::printf("openvr_api load failed: %lu\n",GetLastError());return 2; }
	auto init=reinterpret_cast<uint32_t (*)(vr::EVRInitError *,vr::EVRApplicationType,const char *)>(GetProcAddress(api,"VR_InitInternal2"));
	auto get=reinterpret_cast<void *(*)(const char *,vr::EVRInitError *)>(GetProcAddress(api,"VR_GetGenericInterface"));
	auto shutdown=reinterpret_cast<void (*)()>(GetProcAddress(api,"VR_ShutdownInternal"));
	if(!init || !get || !shutdown) {FreeLibrary(api);return 2;}
	vr::EVRInitError error=vr::VRInitError_None;
	bool scene=argc>3 && wcscmp(argv[3],L"--scene")==0;
	init(&error,scene?vr::VRApplication_Scene:vr::VRApplication_Background,nullptr);
	if(error!=vr::VRInitError_None) {std::printf("init error %d\n",int(error));FreeLibrary(api);return 2;}
	auto system=static_cast<vr::IVRSystem *>(get(vr::IVRSystem_Version,&error));
	if(!system) {std::printf("system error %d\n",int(error));shutdown();FreeLibrary(api);return 2;}
	for(uint32_t id=0;id<vr::k_unMaxTrackedDeviceCount;id++) {
		if(!system->IsTrackedDeviceConnected(id)) continue;
		char model[256]{}, tracking[256]{};
		system->GetStringTrackedDeviceProperty(id,vr::Prop_ModelNumber_String,model,sizeof(model));
		system->GetStringTrackedDeviceProperty(id,vr::Prop_TrackingSystemName_String,tracking,sizeof(tracking));
		std::printf("device %u model=%s tracking=%s axis0=%d supported=%llx\n",id,model,tracking,
			system->GetInt32TrackedDeviceProperty(id,vr::Prop_Axis0Type_Int32),
			static_cast<unsigned long long>(system->GetUint64TrackedDeviceProperty(id,vr::Prop_SupportedButtons_Uint64)));
	}
	int seconds=argc>2?std::clamp(_wtoi(argv[2]),1,120):10;
	float peak[2][2]{};
	unsigned samples[2]{};
	for(int tick=0;tick<seconds*50;tick++) {
		for(int hand=0;hand<2;hand++) {
			auto id=system->GetTrackedDeviceIndexForControllerRole(hand==0?vr::TrackedControllerRole_LeftHand:vr::TrackedControllerRole_RightHand);
			vr::VRControllerState_t state{};
			if(id==vr::k_unTrackedDeviceIndexInvalid || !system->GetControllerState(id,&state,sizeof(state))) continue;
			samples[hand]++;
			peak[hand][0]=std::max(peak[hand][0],std::abs(state.rAxis[0].x));
			peak[hand][1]=std::max(peak[hand][1],std::abs(state.rAxis[0].y));
			if(tick%50==0) std::printf("hand=%d packet=%u stick=(%.3f,%.3f) trigger=%.3f grip=%.3f pressed=%llx touched=%llx\n",
				hand,state.unPacketNum,state.rAxis[0].x,state.rAxis[0].y,state.rAxis[1].x,state.rAxis[2].x,
				static_cast<unsigned long long>(state.ulButtonPressed),static_cast<unsigned long long>(state.ulButtonTouched));
		}
		std::fflush(stdout);Sleep(20);
	}
	for(int hand=0;hand<2;hand++) std::printf("summary hand=%d samples=%u stick_peak=(%.3f,%.3f)\n",hand,samples[hand],peak[hand][0],peak[hand][1]);
	if(!samples[0] && !samples[1]) std::puts("No legacy input samples: no tracked controller or input focus is masked. This does not verify joystick delivery.");
	shutdown();FreeLibrary(api);return 0;
}
