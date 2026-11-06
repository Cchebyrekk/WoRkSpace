#pragma once
// The driver's own compositing in direct mode (slice q1, after the first try in
// the headset: the virtual display gave frames without the pose they were drawn
// with, the headset turned them by a guessed one and the picture shook). SteamVR
// renders into textures made here and submits them as layers, each with the head
// pose it was drawn with; this draws the layers of a frame into one picture —
// both eyes side by side, foveated as branch pc-render sends them (Foveation:
// more pixels in the middle) — which the eyes' stream then takes.

#include <openvr_driver.h>

#include <cstdint>
#include <memory>
#include <string>

class FrameCompositor {
public:
	FrameCompositor();
	~FrameCompositor();

	// A device on the default adapter; its LUID is what SteamVR is told to use.
	bool open(uint32_t eye_width, uint32_t eye_height, float foveation, std::string &error);
	uint64_t adapter_luid() const;
	// The finished picture: a shared texture of 2 x eye_width by eye_height
	// (R8G8B8A8, legacy shared handle) — what the stream copies.
	void *output_handle() const;

	void create_set(uint32_t pid, const vr::IVRDriverDirectModeComponent::SwapTextureSetDesc_t &desc,
			vr::IVRDriverDirectModeComponent::SwapTextureSet_t &out);
	void destroy_set(vr::SharedTextureHandle_t handle);
	void destroy_all(uint32_t pid);
	void next_indices(const vr::SharedTextureHandle_t handles[2], uint32_t (*indices)[2]);

	void add_layer(const vr::IVRDriverDirectModeComponent::SubmitLayerPerEye_t (&eyes)[2]);
	// Draws the frame's layers into the output (once the compositor is done with
	// them: `sync`, its keyed mutex) and waits for the GPU. False if there was
	// nothing to draw. `pose` gets the head pose of the first layer, `projection`
	// its eyes' projections (what the frame was really drawn with). The picture
	// is resampled to `target`, per eye tangents left, right, top, bottom (y down).
	bool compose(vr::SharedTextureHandle_t sync, const float (&target)[2][4], vr::HmdMatrix34_t &pose,
			vr::HmdMatrix44_t (&projection)[2]);

private:
	struct State;
	std::unique_ptr<State> state;
};
