// Game video submitted as a projection, without a world-space video plane.
#include <godot_cpp/classes/open_xr_extension_wrapper.hpp>
#include <godot_cpp/classes/open_xrapi_extension.hpp>
#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/utility_functions.hpp>
#include <openxr/openxr.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <array>
#include <vector>
#include <cmath>
#include <algorithm>
#include <chrono>
#include <mutex>
#include <sstream>
#include <locale>

using namespace godot;

class GameProjection : public OpenXRExtensionWrapper {
 GDCLASS(GameProjection, OpenXRExtensionWrapper)
 Ref<OpenXRAPIExtension> api;
 uint64_t chains[2]{};
 XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
 XrCompositionLayerProjectionView views[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}, {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
 GLuint program=0, source=0, framebuffer=0, vao=0;
 int width=0, height=0;
 bool ready=false, registered=false;
 bool announced=false;
 String error;
 std::mutex timing_mutex;
 using Clock=std::chrono::steady_clock;
 Clock::time_point copied_at;
 double source_age_ms=-1;
 double video_age_ms=-1;
 uint64_t generation=0, submitted_generation=0, reused=0;
 std::vector<double> copy_ms, age_ms, submit_wait_ms, video_ms;

 static void sample(std::vector<double> &values,double value) {
  if(std::isfinite(value) && value>=0 && values.size()<4096) values.push_back(value);
 }
 static void summary(std::ostringstream &out,const char *name,std::vector<double> &values) {
  if(values.empty()) return;
  std::sort(values.begin(),values.end());
  auto p=[&](double q){return values[std::max(size_t(1),size_t(std::ceil(values.size()*q)))-1];};
  out<<"; "<<name<<" n="<<values.size()<<" "<<p(.5)<<"/"<<p(.95)<<"/"<<p(.99)<<"/"<<values.back();
  values.clear();
 }

 GLuint shader(GLenum type, const char *code) {
  GLuint s=glCreateShader(type); glShaderSource(s,1,&code,nullptr); glCompileShader(s);
  GLint ok=0; glGetShaderiv(s,GL_COMPILE_STATUS,&ok);
  if (!ok) { char log[2048]{}; glGetShaderInfoLog(s,sizeof(log),nullptr,log); error=String::utf8(log); glDeleteShader(s); return 0; }
  return s;
 }
 bool graphics() {
  if(program) return true;
  const char *vs=R"(#version 300 es
out vec2 uv;
void main(){ vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2)); uv=p; gl_Position=vec4(p*2.0-1.0,0,1); })";
  const char *fs=R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision highp float;
uniform samplerExternalOES video;
uniform vec2 crop;
uniform float strength;
uniform float eye;
in vec2 uv; out vec4 color;
void main(){
 // OpenXR GLES images use bottom-left origin; decoder image is top-left.
 vec2 s=vec2(uv.x,1.0-uv.y)*2.0-1.0;
 vec2 u=s;
 for(int i=0;i<8;i++) u-=(u*(strength+(1.0-strength)*u*u)-s)/(strength+3.0*(1.0-strength)*u*u);
 vec2 v=u*.5+.5;
 color=vec4(texture(video,vec2((v.x+eye)*.5,v.y)*crop).rgb,1.0);
})";
  GLuint v=shader(GL_VERTEX_SHADER,vs), f=shader(GL_FRAGMENT_SHADER,fs);
  if(!v||!f) { if(v)glDeleteShader(v); if(f)glDeleteShader(f); return false; }
  program=glCreateProgram(); glAttachShader(program,v); glAttachShader(program,f); glLinkProgram(program);
  glDeleteShader(v); glDeleteShader(f); GLint ok=0; glGetProgramiv(program,GL_LINK_STATUS,&ok);
  if(!ok) { error="projection shader link failed"; glDeleteProgram(program); program=0; return false; }
  glGenTextures(1,&source); glGenFramebuffers(1,&framebuffer); glGenVertexArrays(1,&vao);
  return true;
 }
 static XrPosef pose(const Transform3D &t) {
  Quaternion q=t.basis.get_rotation_quaternion();
  return {{float(q.x),float(q.y),float(q.z),float(q.w)}, {float(t.origin.x),float(t.origin.y),float(t.origin.z)}};
 }
 void free_chains() {
  ready=false;
  for(auto &c:chains) { if(c && api.is_valid()) api->openxr_swapchain_free(c); c=0; }
  width=height=0;
 }
protected:
 static void _bind_methods() {
  ClassDB::bind_method(D_METHOD("present", "image", "size", "buffer_size", "eyes", "fov", "strength", "source_age_ms", "video_age_ms"), &GameProjection::present, DEFVAL(-1.0), DEFVAL(-1.0));
  ClassDB::bind_method(D_METHOD("timing_report"), &GameProjection::timing_report);
  ClassDB::bind_method(D_METHOD("clear"), &GameProjection::clear);
  ClassDB::bind_method(D_METHOD("get_error"), &GameProjection::get_error);
 }
public:
 void _on_session_created(uint64_t) override {
  api=get_openxr_api(); api->register_composition_layer_provider(this); registered=true;
 }
 void _on_session_destroyed() override {
  free_chains();
  if(registered) api->unregister_composition_layer_provider(this);
  registered=false;
  // GL resources are session-independent, owned by Godot's EGL context.
 }
 int32_t _get_composition_layer_count() override { return ready ? 1 : 0; }
 uint64_t _get_composition_layer(int32_t) override {
  {
   std::lock_guard<std::mutex> lock(timing_mutex);
   if(generation!=submitted_generation) {
    double wait=std::chrono::duration<double,std::milli>(Clock::now()-copied_at).count();
    sample(submit_wait_ms,wait);
    if(source_age_ms>=0) sample(age_ms,source_age_ms+wait);
    if(video_age_ms>=0) sample(video_ms,video_age_ms+wait);
    submitted_generation=generation;
   } else reused++;
  }
  layer.space=(XrSpace)api->get_play_space();
  return reinterpret_cast<uint64_t>(&layer);
 }
 // Behind the transparent local UI, above any passthrough.
 int32_t _get_composition_layer_order(int32_t) override { return -1; }
 void clear(){
  ready=false;
  std::lock_guard<std::mutex> lock(timing_mutex);
  copy_ms.clear();age_ms.clear();submit_wait_ms.clear();video_ms.clear();
  generation=submitted_generation=reused=0;source_age_ms=video_age_ms=-1;
 }
 String get_error() const {return error;}
 String timing_report() {
  std::lock_guard<std::mutex> lock(timing_mutex);
  std::ostringstream out;out.imbue(std::locale::classic());out.precision(2);out<<std::fixed<<"ms p50/p95/p99/max";
  summary(out,"native_copy",copy_ms);summary(out,"copy_to_layer",submit_wait_ms);summary(out,"matched_pose_to_layer",age_ms);summary(out,"pc_submit_to_layer",video_ms);
  out<<"; layer_reuse="<<reused;reused=0;
  return String::utf8(out.str().c_str());
 }
 bool present(int64_t image, Vector2i size, Vector2i padded, Array eyes, Array fov, double strength,double p_source_age_ms,double p_video_age_ms) {
  auto copy_started=Clock::now();
  if(!registered || !image || eyes.size()!=2 || fov.size()!=2 || size.x<2 || size.y<1 || padded.x<size.x || padded.y<size.y) return false;
  if(eglGetCurrentContext()==EGL_NO_CONTEXT) {error="No current EGL context: projection requires single-threaded renderer"; return false;}
  if(!graphics())return false;
  if(width!=size.x/2 || height!=size.y) {
   free_chains(); width=size.x/2; height=size.y;
   auto formats=api->get_supported_swapchain_formats();
   if(!formats.has(GL_RGBA8)) {error="Runtime does not support RGBA8 swapchain";return false;}
   for(int e=0;e<2;e++) {
    chains[e]=api->openxr_swapchain_create(0,XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT|XR_SWAPCHAIN_USAGE_SAMPLED_BIT,GL_RGBA8,width,height,1,1);
    if(!chains[e]){error="Cannot create projection swapchain";free_chains();return false;}
   }
  }
  auto image_target=(PFNGLEGLIMAGETARGETTEXTURE2DOESPROC)eglGetProcAddress("glEGLImageTargetTexture2DOES");
  if(!image_target){error="EGL image import unsupported";return false;}
  GLint old_program,old_draw,old_read,old_vao,old_active,old_tex,old_sampler,viewport[4]; GLboolean mask[4];
  glGetIntegerv(GL_CURRENT_PROGRAM,&old_program); glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,&old_draw); glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,&old_read);
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,&old_vao); glGetIntegerv(GL_ACTIVE_TEXTURE,&old_active); glGetIntegerv(GL_VIEWPORT,viewport); glGetBooleanv(GL_COLOR_WRITEMASK,mask);
  std::array<GLenum,5> caps{GL_BLEND,GL_DEPTH_TEST,GL_CULL_FACE,GL_SCISSOR_TEST,GL_STENCIL_TEST};
  std::array<GLboolean,5> enabled; for(int i=0;i<5;i++){enabled[i]=glIsEnabled(caps[i]);glDisable(caps[i]);}
  glActiveTexture(GL_TEXTURE0); glGetIntegerv(GL_TEXTURE_BINDING_EXTERNAL_OES,&old_tex);
  glGetIntegerv(GL_SAMPLER_BINDING,&old_sampler);glBindSampler(0,0);
  glBindTexture(GL_TEXTURE_EXTERNAL_OES,source); image_target(GL_TEXTURE_EXTERNAL_OES,(GLeglImageOES)(intptr_t)image);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
  glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_EXTERNAL_OES,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
  glUseProgram(program);glBindVertexArray(vao);glBindFramebuffer(GL_FRAMEBUFFER,framebuffer);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glViewport(0,0,width,height);
  glUniform1i(glGetUniformLocation(program,"video"),0);glUniform1f(glGetUniformLocation(program,"strength"),strength);
  glUniform2f(glGetUniformLocation(program,"crop"),float(size.x)/padded.x,float(size.y)/padded.y);
  bool ok=true;
  for(int e=0;e<2;e++) {
   api->openxr_swapchain_acquire(chains[e]);
   RID texture=api->openxr_swapchain_get_image(chains[e]);
   GLuint handle=(GLuint)RenderingServer::get_singleton()->texture_get_native_handle(texture);
   glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,handle,0);
   if(glCheckFramebufferStatus(GL_FRAMEBUFFER)!=GL_FRAMEBUFFER_COMPLETE) {ok=false;error="Incomplete projection framebuffer";}
   else {glUniform1f(glGetUniformLocation(program,"eye"),e);glDrawArrays(GL_TRIANGLES,0,3);}
   glFlush(); api->openxr_swapchain_release(chains[e]);
   Vector4 t=fov[e]; views[e].pose=pose(eyes[e]);
   views[e].fov={float(atan(t.x)),float(atan(t.y)),float(atan(t.w)),float(atan(t.z))};
   views[e].subImage={(XrSwapchain)api->openxr_swapchain_get_swapchain(chains[e]),{{0,0},{width,height}},0};
  }
  // The decoder owns the source image; finish before returning its lease to Java.
  glFinish();
  glBindTexture(GL_TEXTURE_EXTERNAL_OES,old_tex);glBindSampler(0,old_sampler);glActiveTexture(old_active);glUseProgram(old_program);glBindVertexArray(old_vao);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER,old_draw);glBindFramebuffer(GL_READ_FRAMEBUFFER,old_read);glViewport(viewport[0],viewport[1],viewport[2],viewport[3]);glColorMask(mask[0],mask[1],mask[2],mask[3]);
  for(int i=0;i<5;i++)if(enabled[i])glEnable(caps[i]);
  layer.viewCount=2;layer.views=views;ready=ok;
  if(ok) {
   std::lock_guard<std::mutex> lock(timing_mutex);
   copied_at=Clock::now();
   double elapsed=std::chrono::duration<double,std::milli>(copied_at-copy_started).count();
   sample(copy_ms,elapsed);source_age_ms=p_source_age_ms<0?-1:p_source_age_ms+elapsed;
   video_age_ms=p_video_age_ms<0?-1:p_video_age_ms+elapsed;generation++;
  }
  if(ok && !announced){UtilityFunctions::print("[projection] native OpenXR projection active: ",width,"x",height," per eye");announced=true;}
  return ok;
 }
};

static GameProjection *projection=nullptr;
static void init(ModuleInitializationLevel level){
 if(level!=MODULE_INITIALIZATION_LEVEL_CORE)return;
 GDREGISTER_CLASS(GameProjection);
 projection=memnew(GameProjection);
 projection->register_extension_wrapper();
 Engine::get_singleton()->register_singleton("GameProjection",projection);
}
static void deinit(ModuleInitializationLevel level){
 if(level!=MODULE_INITIALIZATION_LEVEL_CORE)return;
 Engine::get_singleton()->unregister_singleton("GameProjection");
 // OpenXR owns the registered wrapper and disposes it on shutdown.
}
extern "C" GDExtensionBool GDE_EXPORT workplace_projection_init(GDExtensionInterfaceGetProcAddress proc,GDExtensionClassLibraryPtr library,GDExtensionInitialization *initialization){
 GDExtensionBinding::InitObject object(proc,library,initialization);object.register_initializer(init);object.register_terminator(deinit);object.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_CORE);return object.init();
}
