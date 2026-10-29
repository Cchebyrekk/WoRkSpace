package com.workplace.headset;

import android.hardware.HardwareBuffer;

/** EGLImages of decoded frames for Godot's ExternalTexture (jni/hardware_buffers.c). */
final class HardwareBuffers {
	static {
		System.loadLibrary("workplace_hwb");
	}

	private HardwareBuffers() {
	}

	/** On Godot's render thread; 0 when no image could be made. */
	static native long image(HardwareBuffer buffer);

	/** From any thread, for an image made by image(). */
	static native void destroy(long image);
}
