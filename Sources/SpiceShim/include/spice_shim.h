#ifndef VMM_SPICE_SHIM_H
#define VMM_SPICE_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VMMSpiceSession VMMSpiceSession;

/* Callbacks are invoked on the SPICE session's GLib thread — the Swift side
   must hop to the main thread before touching UI. `ctx` is the opaque pointer
   passed to vmm_spice_session_create. */
typedef struct {
    void *ctx;
    /* A new primary framebuffer exists. `data` is a 32-bit-per-pixel buffer
       (cairo RGB24 layout: little-endian 0x00RRGGBB) of `height` rows of
       `stride` bytes, valid until primary_destroy / session stop. */
    void (*primary_create)(void *ctx, int format, int width, int height,
                           int stride, const uint8_t *data);
    void (*primary_destroy)(void *ctx);
    /* A rectangle of the framebuffer changed. */
    void (*invalidate)(void *ctx, int x, int y, int w, int h);
    /* connected = 1 when the console is usable; 0 on disconnect/error.
       `error` is NULL unless a failure occurred. */
    void (*state)(void *ctx, int connected, const char *error);
    /* SPICE clipboard (UTF-8 text). Invoked on the runner thread. */
    void (*clipboard_guest_grab)(void *ctx, unsigned selection,
                                 const uint32_t *types, int ntypes);
    void (*clipboard_guest_request)(void *ctx, unsigned selection, uint32_t type);
    void (*clipboard_guest_release)(void *ctx, unsigned selection);
    void (*clipboard_guest_data)(void *ctx, unsigned selection, uint32_t type,
                                 const uint8_t *data, size_t size);
    /* Guest monitor layout changed (plug/unplug or SPICE reconfig). Runner thread. */
    void (*monitors_changed)(void *ctx);
    /* Guest is pushing GL scanout frames (no standard framebuffer). Runner thread. */
    void (*gl_scanout_active)(void *ctx, int active);
} VMMSpiceCallbacks;

/** One guest display surface reported by a SPICE display channel. */
typedef struct {
    int channel_id;
    int monitor_id;
    int x;
    int y;
    int width;
    int height;
} VMMMonitorInfo;

/* Create a session for host:port (typically 127.0.0.1:<tunnel port>). */
VMMSpiceSession *vmm_spice_session_create(const char *host, int port,
                                          const char *password,
                                          VMMSpiceCallbacks callbacks);

/* Spawn the GLib loop thread and begin connecting. */
void vmm_spice_session_start(VMMSpiceSession *s);

/* Disconnect, stop the loop, join the thread and free everything. */
void vmm_spice_session_stop(VMMSpiceSession *s);

/* Input — safe to call from any thread; marshalled onto the session thread.
   `scancode` is a PC XT (set 1) scancode; extended keys use 0xE0 in the high
   byte (e.g. 0xE048 for Up). `button_mask` is a SPICE button mask. */
void vmm_spice_key(VMMSpiceSession *s, uint32_t scancode, int down);
void vmm_spice_mouse_motion_abs(VMMSpiceSession *s, int x, int y, int button_mask);
void vmm_spice_mouse_button(VMMSpiceSession *s, int button, int button_mask, int down);
void vmm_spice_mouse_wheel(VMMSpiceSession *s, int up, int button_mask);

void vmm_spice_clipboard_enable(VMMSpiceSession *s, int enabled);
void vmm_spice_clipboard_host_grab(VMMSpiceSession *s);
void vmm_spice_clipboard_host_notify(VMMSpiceSession *s, uint32_t type,
                                     const uint8_t *data, size_t size);

/* Guest audio (playback + microphone via spice-gtk / GStreamer). */
void vmm_spice_audio_enable(VMMSpiceSession *s, int enabled);

int vmm_spice_list_monitors(VMMSpiceSession *s, VMMMonitorInfo *out, int max_count);
void vmm_spice_select_monitor(VMMSpiceSession *s, int channel_id, int monitor_id);

const char *vmm_spice_version(void);

#ifdef __cplusplus
}
#endif

#endif /* VMM_SPICE_SHIM_H */
