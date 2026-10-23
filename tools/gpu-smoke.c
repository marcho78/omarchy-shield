/*
 * The smallest picture the desktop needs: KMS + GBM + EGL + GLES2, the way a
 * Wayland compositor uses them. tegra-drm shows it, nouveau draws it, and
 * Mesa's tegra driver joins the two. The TV shows a slow colour fade with a
 * white triangle turning on it, then the console comes back.
 *
 * Every step is printed before it runs, so a crash names its step.
 *
 * On the SHIELD:
 *   ssh root@<addr> 'cat > gpu-smoke.c' < tools/gpu-smoke.c
 *   ssh root@<addr> 'gcc -O1 -g -o gpu-smoke gpu-smoke.c -I/usr/include/libdrm \
 *     -ldrm -lgbm -lEGL -lGLESv2 -lm'
 *   ssh root@<addr> './gpu-smoke /dev/dri/by-path/platform-50000000.host1x-card 10'
 */
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <xf86drm.h>
#include <xf86drmMode.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

static void step(const char *s)
{
	fprintf(stderr, "step: %s\n", s);
}

static void die(const char *s)
{
	fprintf(stderr, "failed: %s (errno %d, EGL error 0x%x)\n", s, errno,
		eglGetError());
	exit(1);
}

static void flip_done(int fd, unsigned int seq, unsigned int sec,
		      unsigned int usec, void *data)
{
	*(int *)data = 0;
}

static const char *vs_src =
	"attribute vec2 pos;\n"
	"uniform float angle;\n"
	"void main() {\n"
	"  float c = cos(angle), s = sin(angle);\n"
	"  gl_Position = vec4(c * pos.x - s * pos.y, s * pos.x + c * pos.y, 0.0, 1.0);\n"
	"}\n";

static const char *fs_src =
	"precision mediump float;\n"
	"void main() { gl_FragColor = vec4(1.0); }\n";

static GLuint shader(GLenum type, const char *src)
{
	GLuint s = glCreateShader(type);
	GLint ok;
	char log[512];

	glShaderSource(s, 1, &src, NULL);
	glCompileShader(s);
	glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
	if (!ok) {
		glGetShaderInfoLog(s, sizeof(log), NULL, log);
		fprintf(stderr, "%s\n", log);
		die("glCompileShader");
	}
	return s;
}

int main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/dev/dri/card1";
	int frames = (argc > 2 ? atoi(argv[2]) : 10) * 60;
	drmModeConnector *conn = NULL;
	drmModeEncoder *enc;
	drmModeModeInfo mode;
	drmModeCrtc *saved;
	uint32_t crtc_id;
	struct gbm_bo *prev = NULL;
	uint32_t prev_fb = 0;

	step("open the KMS device");
	int fd = open(path, O_RDWR | O_CLOEXEC);
	if (fd < 0)
		die("open");

	step("find the connected connector and its mode");
	drmModeRes *res = drmModeGetResources(fd);
	if (!res)
		die("drmModeGetResources");
	for (int i = 0; i < res->count_connectors && !conn; i++) {
		conn = drmModeGetConnector(fd, res->connectors[i]);
		if (conn && (conn->connection != DRM_MODE_CONNECTED ||
			     !conn->count_modes)) {
			drmModeFreeConnector(conn);
			conn = NULL;
		}
	}
	if (!conn)
		die("no connected connector");
	mode = conn->modes[0];
	for (int i = 0; i < conn->count_modes; i++)
		if (conn->modes[i].type & DRM_MODE_TYPE_PREFERRED) {
			mode = conn->modes[i];
			break;
		}
	enc = drmModeGetEncoder(fd, conn->encoder_id);
	if (!enc || !enc->crtc_id)
		die("the connector has no CRTC (is the console on it?)");
	crtc_id = enc->crtc_id;
	saved = drmModeGetCrtc(fd, crtc_id);
	fprintf(stderr, "  %s on CRTC %u\n", mode.name, crtc_id);

	step("gbm_create_device");
	struct gbm_device *gbm = gbm_create_device(fd);
	if (!gbm)
		die("gbm_create_device");
	fprintf(stderr, "  GBM backend: %s\n", gbm_device_get_backend_name(gbm));

	step("gbm_surface_create (XRGB8888, scanout and rendering)");
	struct gbm_surface *gs = gbm_surface_create(gbm, mode.hdisplay,
						    mode.vdisplay,
						    GBM_FORMAT_XRGB8888,
						    GBM_BO_USE_SCANOUT |
						    GBM_BO_USE_RENDERING);
	if (!gs)
		die("gbm_surface_create");

	step("eglGetPlatformDisplay and eglInitialize");
	EGLDisplay dpy = eglGetPlatformDisplay(EGL_PLATFORM_GBM_KHR, gbm, NULL);
	EGLint major, minor;
	if (dpy == EGL_NO_DISPLAY || !eglInitialize(dpy, &major, &minor))
		die("eglInitialize");
	fprintf(stderr, "  EGL %d.%d, %s\n", major, minor,
		eglQueryString(dpy, EGL_VENDOR));
	eglBindAPI(EGL_OPENGL_ES_API);

	step("choose an EGL config whose visual is XRGB8888");
	EGLint attrs[] = {
		EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
		EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
		EGL_ALPHA_SIZE, 0,
		EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
		EGL_NONE
	};
	EGLConfig cfgs[64], cfg = NULL;
	EGLint n = 0;
	eglChooseConfig(dpy, attrs, cfgs, 64, &n);
	for (int i = 0; i < n && !cfg; i++) {
		EGLint id;

		eglGetConfigAttrib(dpy, cfgs[i], EGL_NATIVE_VISUAL_ID, &id);
		if (id == GBM_FORMAT_XRGB8888)
			cfg = cfgs[i];
	}
	if (!cfg)
		die("no XRGB8888 config");

	step("eglCreateContext (GLES 2)");
	EGLint ctx_attrs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
	EGLContext ctx = eglCreateContext(dpy, cfg, EGL_NO_CONTEXT, ctx_attrs);
	if (ctx == EGL_NO_CONTEXT)
		die("eglCreateContext");

	step("eglCreatePlatformWindowSurface");
	EGLSurface surf = eglCreatePlatformWindowSurface(dpy, cfg, gs, NULL);
	if (surf == EGL_NO_SURFACE)
		die("eglCreatePlatformWindowSurface");

	step("eglMakeCurrent");
	if (!eglMakeCurrent(dpy, surf, surf, ctx))
		die("eglMakeCurrent");

	step("glGetString");
	fprintf(stderr, "  %s, %s\n", glGetString(GL_RENDERER),
		glGetString(GL_VERSION));

	step("glViewport");
	glViewport(0, 0, mode.hdisplay, mode.vdisplay);

	step("glClear");
	glClearColor(0, 0, 0, 1);
	glClear(GL_COLOR_BUFFER_BIT);

	step("compile and link the shaders");
	GLuint prog = glCreateProgram();
	GLint ok;
	glAttachShader(prog, shader(GL_VERTEX_SHADER, vs_src));
	glAttachShader(prog, shader(GL_FRAGMENT_SHADER, fs_src));
	glBindAttribLocation(prog, 0, "pos");
	glLinkProgram(prog);
	glGetProgramiv(prog, GL_LINK_STATUS, &ok);
	if (!ok)
		die("glLinkProgram");
	glUseProgram(prog);
	GLint angle = glGetUniformLocation(prog, "angle");
	static const GLfloat tri[] = { 0.0f, 0.6f, -0.5f, -0.4f, 0.5f, -0.4f };
	glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, tri);
	glEnableVertexAttribArray(0);

	for (int i = 0; i < frames; i++) {
		float t = i / 60.0f;
		uint32_t handles[4] = { 0 }, pitches[4] = { 0 };
		uint32_t offsets[4] = { 0 }, fb;
		uint64_t mods[4] = { 0 };
		struct gbm_bo *bo;
		int err;

		glClearColor(0.5f + 0.4f * sinf(t), 0.5f + 0.4f * sinf(t + 2.1f),
			     0.5f + 0.4f * sinf(t + 4.2f), 1.0f);
		glClear(GL_COLOR_BUFFER_BIT);
		glUniform1f(angle, t);
		if (i == 0)
			step("glDrawArrays");
		glDrawArrays(GL_TRIANGLES, 0, 3);
		if (i == 0)
			step("eglSwapBuffers");
		if (!eglSwapBuffers(dpy, surf))
			die("eglSwapBuffers");

		if (i == 0)
			step("gbm_surface_lock_front_buffer and drmModeAddFB2");
		bo = gbm_surface_lock_front_buffer(gs);
		if (!bo)
			die("gbm_surface_lock_front_buffer");
		handles[0] = gbm_bo_get_handle(bo).u32;
		pitches[0] = gbm_bo_get_stride(bo);
		mods[0] = gbm_bo_get_modifier(bo);
		if (i == 0)
			fprintf(stderr, "  buffer %ux%u, stride %u, modifier 0x%llx\n",
				gbm_bo_get_width(bo), gbm_bo_get_height(bo),
				pitches[0], (unsigned long long)mods[0]);
		if (mods[0] != DRM_FORMAT_MOD_INVALID)
			err = drmModeAddFB2WithModifiers(fd, mode.hdisplay,
							 mode.vdisplay,
							 GBM_FORMAT_XRGB8888,
							 handles, pitches,
							 offsets, mods, &fb,
							 DRM_MODE_FB_MODIFIERS);
		else
			err = drmModeAddFB2(fd, mode.hdisplay, mode.vdisplay,
					    GBM_FORMAT_XRGB8888, handles,
					    pitches, offsets, &fb, 0);
		if (err)
			die("drmModeAddFB2");

		if (i == 0) {
			step("drmModeSetCrtc");
			if (drmModeSetCrtc(fd, crtc_id, fb, 0, 0,
					   &conn->connector_id, 1, &mode))
				die("drmModeSetCrtc");
		} else {
			drmEventContext ev = {
				.version = 2,
				.page_flip_handler = flip_done,
			};
			struct pollfd pfd = { .fd = fd, .events = POLLIN };
			int pending = 1;

			if (drmModePageFlip(fd, crtc_id, fb,
					    DRM_MODE_PAGE_FLIP_EVENT, &pending))
				die("drmModePageFlip");
			while (pending) {
				if (poll(&pfd, 1, 1000) != 1)
					die("no page flip within 1 s");
				drmHandleEvent(fd, &ev);
			}
			if (i == 1)
				step("page flips running");
		}

		if (prev) {
			drmModeRmFB(fd, prev_fb);
			gbm_surface_release_buffer(gs, prev);
		}
		prev = bo;
		prev_fb = fb;
	}

	step("give the screen back to the console");
	if (saved)
		drmModeSetCrtc(fd, saved->crtc_id, saved->buffer_id, saved->x,
			       saved->y, &conn->connector_id, 1, &saved->mode);
	fprintf(stderr, "done: %d frames\n", frames);
	return 0;
}
