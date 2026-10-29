// The one native piece of the headset's video receiver (convex screens): an
// EGLImage of a decoded frame's AHardwareBuffer, which Godot's ExternalTexture
// takes (set_external_buffer_id) on the Compatibility renderer; the Mobile one
// (Vulkan) ignores external buffers (slice o5d, 29.10.2026). Called on Godot's
// render thread, where its EGL context is current. Java keeps the frame
// (android.media.Image) open while Godot may still sample it.

#include <jni.h>
#include <stdint.h>
#include <android/hardware_buffer_jni.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>

// The display the images were made on: they are destroyed from the receiver's thread.
static EGLDisplay display = EGL_NO_DISPLAY;
static PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC get_client_buffer = NULL;
static PFNEGLCREATEIMAGEKHRPROC create_image = NULL;
static PFNEGLDESTROYIMAGEKHRPROC destroy_image = NULL;

JNIEXPORT jlong JNICALL Java_com_workplace_headset_HardwareBuffers_image(JNIEnv *env, jclass type, jobject buffer) {
	(void)type;
	if (buffer == NULL) {
		return 0;
	}
	if (create_image == NULL) {
		get_client_buffer = (PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)eglGetProcAddress("eglGetNativeClientBufferANDROID");
		create_image = (PFNEGLCREATEIMAGEKHRPROC)eglGetProcAddress("eglCreateImageKHR");
		destroy_image = (PFNEGLDESTROYIMAGEKHRPROC)eglGetProcAddress("eglDestroyImageKHR");
		if (get_client_buffer == NULL || create_image == NULL || destroy_image == NULL) {
			create_image = NULL;
			return 0;
		}
	}
	EGLDisplay current = eglGetCurrentDisplay();
	if (current == EGL_NO_DISPLAY) {
		return 0;
	}
	display = current;
	AHardwareBuffer *native = AHardwareBuffer_fromHardwareBuffer(env, buffer);
	EGLClientBuffer client = get_client_buffer(native);
	if (client == NULL) {
		return 0;
	}
	const EGLint attributes[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
	EGLImageKHR image = create_image(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID, client, attributes);
	return image == EGL_NO_IMAGE_KHR ? 0 : (jlong)(intptr_t)image;
}

JNIEXPORT void JNICALL Java_com_workplace_headset_HardwareBuffers_destroy(JNIEnv *env, jclass type, jlong image) {
	(void)env;
	(void)type;
	if (image != 0 && destroy_image != NULL && display != EGL_NO_DISPLAY) {
		destroy_image(display, (EGLImageKHR)(intptr_t)image);
	}
}
