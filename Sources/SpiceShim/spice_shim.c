#include "spice_shim.h"

#include <spice-client.h>
#include <channel-main.h>
#include <spice-audio.h>
#include <usb-device-manager.h>
#include <spice/vd_agent.h>
#include <glib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Diagnostics, silent unless VMM_SPICE_DEBUG is set in the environment. */
#define SHIMLOG(...) do { if (getenv("VMM_SPICE_DEBUG")) { \
    fprintf(stderr, "VMMSPICE: " __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } } while (0)

struct VMMSpiceSession {
    char *host;
    int   port;
    char *password;
    VMMSpiceCallbacks cb;

    SpiceSession       *session;
    SpiceChannel       *main_channel;
    SpiceChannel       *display;
    SpiceInputsChannel *inputs;

    int announced_connected;
    int started;

    int clipboard_enabled;
    int host_clip_grabbed;
    guint clipboard_release_src;

    int audio_enabled;
    int usb_enabled;
    SpiceUsbDeviceManager *usb_manager;
    gulong usb_added_id;
    gulong usb_removed_id;
};

/* ---- Shared GLib runner ------------------------------------------------- *
 * spice-gtk schedules parts of its connect path with g_idle_add(), which only
 * ever attaches to GLib's *global default* main context. That context can be
 * owned (run) by exactly one thread. So we run it on ONE long-lived runner
 * thread and create/connect/destroy every SPICE session on it (virt-viewer
 * works the same way: a single main loop, many sessions). Spawning a thread
 * per session — each running the default context — corrupts the heap the
 * moment two sessions overlap (e.g. switching VMs). */
static GMutex        g_runner_mutex;
static GMainContext *g_runner_ctx = NULL;
static GMainLoop    *g_runner_loop = NULL;
static GThread      *g_runner_thread = NULL;

static gpointer runner_main(gpointer data) {
    (void)data;
    g_main_loop_run(g_runner_loop);   /* runs forever for the app's lifetime */
    return NULL;
}

static void ensure_runner(void) {
    g_mutex_lock(&g_runner_mutex);
    if (!g_runner_thread) {
        g_runner_ctx = g_main_context_ref(g_main_context_default());
        g_runner_loop = g_main_loop_new(g_runner_ctx, FALSE);
        g_runner_thread = g_thread_new("vmm-spice-runner", runner_main, NULL);
    }
    g_mutex_unlock(&g_runner_mutex);
}

/* ---- display channel signals (run on the runner thread) ---- */

static void on_primary_create(SpiceChannel *channel, gint format, gint width,
                              gint height, gint stride, gint shmid,
                              gpointer imgdata, gpointer user_data) {
    (void)channel; (void)shmid;
    VMMSpiceSession *s = user_data;
    SHIMLOG("primary-create %dx%d format=%d stride=%d", width, height, format, stride);
    if (s->cb.primary_create)
        s->cb.primary_create(s->cb.ctx, format, width, height, stride,
                             (const uint8_t *)imgdata);
    if (!s->announced_connected && s->cb.state) {
        s->announced_connected = 1;
        s->cb.state(s->cb.ctx, 1, NULL);
    }
}

static void on_primary_destroy(SpiceChannel *channel, gpointer user_data) {
    (void)channel;
    VMMSpiceSession *s = user_data;
    if (s->cb.primary_destroy) s->cb.primary_destroy(s->cb.ctx);
}

static void on_invalidate(SpiceChannel *channel, gint x, gint y, gint w, gint h,
                          gpointer user_data) {
    (void)channel;
    VMMSpiceSession *s = user_data;
    if (s->cb.invalidate) s->cb.invalidate(s->cb.ctx, x, y, w, h);
}

static void on_gl_draw(SpiceChannel *channel, guint32 x, guint32 y,
                       guint32 w, guint32 h, gpointer user_data) {
    (void)channel; (void)x; (void)y; (void)user_data;
    SHIMLOG("gl-draw %ux%u (VM uses GL scanout / virtio-gpu)", w, h);
}

static void on_channel_event(SpiceChannel *channel, SpiceChannelEvent event,
                             gpointer user_data) {
    VMMSpiceSession *s = user_data;
    int type = -1;
    g_object_get(channel, "channel-type", &type, NULL);
    SHIMLOG("channel-event type=%d event=%d", type, (int)event);
    /* Only the main channel drives overall session state. */
    if (!s->cb.state || type != SPICE_CHANNEL_MAIN) return;
    switch (event) {
    case SPICE_CHANNEL_CLOSED:
        s->cb.state(s->cb.ctx, 0, NULL);
        break;
    case SPICE_CHANNEL_ERROR_CONNECT:
        s->cb.state(s->cb.ctx, 0, "Could not connect to SPICE server");
        break;
    case SPICE_CHANNEL_ERROR_TLS:
        s->cb.state(s->cb.ctx, 0, "SPICE TLS error");
        break;
    case SPICE_CHANNEL_ERROR_LINK:
        s->cb.state(s->cb.ctx, 0, "SPICE link error");
        break;
    case SPICE_CHANNEL_ERROR_AUTH:
        s->cb.state(s->cb.ctx, 0, "SPICE authentication failed (wrong password?)");
        break;
    case SPICE_CHANNEL_ERROR_IO:
        s->cb.state(s->cb.ctx, 0, "SPICE I/O error");
        break;
    default:
        break;
    }
}

/* ---- clipboard (UTF-8 text via vdagent) ---- */

#define CLIPBOARD_RELEASE_DELAY_MS 500

static gboolean clipboard_release_timeout(gpointer data) {
    VMMSpiceSession *s = data;
    s->clipboard_release_src = 0;
    if (s->cb.clipboard_guest_release)
        s->cb.clipboard_guest_release(s->cb.ctx, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD);
    return G_SOURCE_REMOVE;
}

static gboolean on_clipboard_grab(SpiceMainChannel *main, guint selection,
                                  guint32 *types, guint32 ntypes,
                                  gpointer user_data) {
    (void)main;
    VMMSpiceSession *s = user_data;
    if (s->clipboard_release_src) {
        g_source_remove(s->clipboard_release_src);
        s->clipboard_release_src = 0;
    }
    if (!s->clipboard_enabled || !s->cb.clipboard_guest_grab)
        return TRUE;
    s->cb.clipboard_guest_grab(s->cb.ctx, selection, types, (int)ntypes);
    /* Guest grabbed — request UTF-8 so we can mirror it to the Mac pasteboard. */
    for (guint i = 0; i < ntypes; i++) {
        if (types[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
            spice_main_channel_clipboard_selection_request(
                SPICE_MAIN_CHANNEL(s->main_channel),
                selection, VD_AGENT_CLIPBOARD_UTF8_TEXT);
            break;
        }
    }
    return TRUE;
}

static gboolean on_clipboard_request(SpiceMainChannel *main, guint selection,
                                     guint type, gpointer user_data) {
    (void)main;
    VMMSpiceSession *s = user_data;
    if (!s->clipboard_enabled || !s->host_clip_grabbed || !s->cb.clipboard_guest_request)
        return FALSE;
    s->cb.clipboard_guest_request(s->cb.ctx, selection, type);
    return TRUE;
}

static void on_clipboard_release(SpiceMainChannel *main, guint selection,
                                 gpointer user_data) {
    (void)main;
    VMMSpiceSession *s = user_data;
    if (!s->clipboard_enabled)
        return;
    if (s->clipboard_release_src)
        g_source_remove(s->clipboard_release_src);
    s->clipboard_release_src = g_timeout_add(CLIPBOARD_RELEASE_DELAY_MS,
                                             clipboard_release_timeout, s);
    (void)selection;
}

static void on_clipboard_data(SpiceMainChannel *main, guint selection,
                              guint type, gpointer data, guint size,
                              gpointer user_data) {
    (void)main;
    VMMSpiceSession *s = user_data;
    if (!s->clipboard_enabled || !s->cb.clipboard_guest_data || !data || size == 0)
        return;
    s->cb.clipboard_guest_data(s->cb.ctx, selection, type, (const uint8_t *)data, size);
}

static gboolean host_grab_cb(gpointer data) {
    VMMSpiceSession *s = data;
    if (!s->main_channel)
        return G_SOURCE_REMOVE;
    guint32 types[] = { VD_AGENT_CLIPBOARD_UTF8_TEXT };
    spice_main_channel_clipboard_selection_grab(
        SPICE_MAIN_CHANNEL(s->main_channel),
        VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, types, 1);
    s->host_clip_grabbed = 1;
    return G_SOURCE_REMOVE;
}

static gboolean host_notify_cb(gpointer data) {
    typedef struct { VMMSpiceSession *s; uint32_t type; GByteArray *bytes; } NotifyOp;
    NotifyOp *op = data;
    if (op->s->main_channel && op->bytes && op->bytes->len > 0) {
        spice_main_channel_clipboard_selection_notify(
            SPICE_MAIN_CHANNEL(op->s->main_channel),
            VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD,
            op->type, op->bytes->data, op->bytes->len);
    }
    if (op->bytes) g_byte_array_free(op->bytes, TRUE);
    g_free(op);
    return G_SOURCE_REMOVE;
}

/* ---- session channel discovery ---- */

static void on_channel_new(SpiceSession *session, SpiceChannel *channel,
                           gpointer user_data) {
    (void)session;
    VMMSpiceSession *s = user_data;
    int type = -1;
    g_object_get(channel, "channel-type", &type, NULL);
    SHIMLOG("channel-new type=%d", type);

    g_signal_connect(channel, "channel-event", G_CALLBACK(on_channel_event), s);

    if (type == SPICE_CHANNEL_MAIN) {
        s->main_channel = channel;
        g_signal_connect(channel, "main-clipboard-selection-grab",
                         G_CALLBACK(on_clipboard_grab), s);
        g_signal_connect(channel, "main-clipboard-selection-request",
                         G_CALLBACK(on_clipboard_request), s);
        g_signal_connect(channel, "main-clipboard-selection-release",
                         G_CALLBACK(on_clipboard_release), s);
        g_signal_connect(channel, "main-clipboard-selection",
                         G_CALLBACK(on_clipboard_data), s);
    } else if (type == SPICE_CHANNEL_DISPLAY) {
        int id = -1;
        g_object_get(channel, "channel-id", &id, NULL);
        if (id != 0) return; /* primary display only */
        s->display = channel;
        g_signal_connect(channel, "display-primary-create", G_CALLBACK(on_primary_create), s);
        g_signal_connect(channel, "display-primary-destroy", G_CALLBACK(on_primary_destroy), s);
        g_signal_connect(channel, "display-invalidate", G_CALLBACK(on_invalidate), s);
        g_signal_connect(channel, "gl-draw", G_CALLBACK(on_gl_draw), s);
        /* Secondary channels are created but not auto-connected. */
        spice_channel_connect(channel);
    } else if (type == SPICE_CHANNEL_INPUTS) {
        s->inputs = SPICE_INPUTS_CHANNEL(channel);
        spice_channel_connect(channel);
    } else if (type == SPICE_CHANNEL_PLAYBACK || type == SPICE_CHANNEL_RECORD) {
        SHIMLOG("channel-new audio type=%d (handled by SpiceAudio)", type);
    } else if (type == SPICE_CHANNEL_USBREDIR) {
        SHIMLOG("channel-new usbredir (handled by SpiceUsbDeviceManager)");
    }
}

static void on_channel_destroy(SpiceSession *session, SpiceChannel *channel,
                               gpointer user_data) {
    (void)session;
    VMMSpiceSession *s = user_data;
    if (channel == s->display) s->display = NULL;
    if (channel == s->main_channel) s->main_channel = NULL;
    if (SPICE_CHANNEL(s->inputs) == channel) s->inputs = NULL;
}

/* ---- USB device redirection --------------------------------------------- */

static void notify_usb_changed(VMMSpiceSession *s) {
    if (s->cb.usb_devices_changed)
        s->cb.usb_devices_changed(s->cb.ctx);
}

static void on_usb_device_added(SpiceUsbDeviceManager *mgr, SpiceUsbDevice *device,
                                gpointer user_data) {
    (void)mgr; (void)device;
    notify_usb_changed((VMMSpiceSession *)user_data);
}

static void on_usb_device_removed(SpiceUsbDeviceManager *mgr, SpiceUsbDevice *device,
                                  gpointer user_data) {
    (void)mgr; (void)device;
    notify_usb_changed((VMMSpiceSession *)user_data);
}

static uint32_t usb_device_id(SpiceUsbDevice *device) {
    /* Opaque SpiceUsbDevice pointer — stable while the device remains plugged in. */
    return (uint32_t)(uintptr_t)device;
}

static void fill_usb_info(SpiceUsbDeviceManager *mgr, SpiceUsbDevice *device,
                          VMMUsbDeviceInfo *info) {
    memset(info, 0, sizeof(*info));
    info->id = usb_device_id(device);
    gchar *desc = spice_usb_device_get_description(device, NULL);
    if (desc) {
        g_strlcpy(info->description, desc, sizeof(info->description));
        g_free(desc);
    } else {
        g_strlcpy(info->description, "USB device", sizeof(info->description));
    }
    info->connected = spice_usb_device_manager_is_device_connected(mgr, device) ? 1 : 0;
    GError *err = NULL;
    info->can_redirect = spice_usb_device_manager_can_redirect_device(mgr, device, &err) ? 1 : 0;
    if (err) {
        g_strlcpy(info->block_reason, err->message, sizeof(info->block_reason));
        g_clear_error(&err);
    }
}

static SpiceUsbDevice *find_usb_device(SpiceUsbDeviceManager *mgr, uint32_t device_id) {
    GPtrArray *devices = spice_usb_device_manager_get_devices(mgr);
    for (guint i = 0; i < devices->len; i++) {
        SpiceUsbDevice *device = g_ptr_array_index(devices, i);
        if (usb_device_id(device) == device_id)
            return device;
    }
    return NULL;
}

static void detach_usb_signals(VMMSpiceSession *s) {
    if (!s->usb_manager)
        return;
    if (s->usb_added_id) {
        g_signal_handler_disconnect(s->usb_manager, s->usb_added_id);
        s->usb_added_id = 0;
    }
    if (s->usb_removed_id) {
        g_signal_handler_disconnect(s->usb_manager, s->usb_removed_id);
        s->usb_removed_id = 0;
    }
    s->usb_manager = NULL;
}

typedef struct {
    VMMSpiceSession *s;
    VMMUsbDeviceInfo *out;
    int max_count;
    int count;
    GMutex m;
    GCond c;
    int done;
} UsbListOp;

static gboolean usb_list_cb(gpointer data) {
    UsbListOp *op = data;
    VMMSpiceSession *s = op->s;
    op->count = 0;
    if (s->usb_manager && op->out && op->max_count > 0) {
        GPtrArray *devices = spice_usb_device_manager_get_devices(s->usb_manager);
        for (guint i = 0; i < devices->len && op->count < op->max_count; i++) {
            fill_usb_info(s->usb_manager, g_ptr_array_index(devices, i),
                          &op->out[op->count++]);
        }
    }
    g_mutex_lock(&op->m);
    op->done = 1;
    g_cond_signal(&op->c);
    g_mutex_unlock(&op->m);
    return G_SOURCE_REMOVE;
}

typedef struct {
    VMMSpiceSession *s;
    uint32_t device_id;
    int connect;
} UsbRedirectOp;

static void usb_redirect_done(GObject *source, GAsyncResult *res, gpointer data) {
    (void)source;
    UsbRedirectOp *op = data;
    VMMSpiceSession *s = op->s;
    GError *err = NULL;
    gboolean ok;
    if (op->connect)
        ok = spice_usb_device_manager_connect_device_finish(s->usb_manager, res, &err);
    else
        ok = spice_usb_device_manager_disconnect_device_finish(s->usb_manager, res, &err);
    if (s->cb.usb_redirect_result)
        s->cb.usb_redirect_result(s->cb.ctx, op->device_id, ok ? 1 : 0,
                                  err ? err->message : NULL);
    g_clear_error(&err);
    notify_usb_changed(s);
    g_free(op);
}

static gboolean usb_redirect_cb(gpointer data) {
    UsbRedirectOp *op = data;
    VMMSpiceSession *s = op->s;
    const char *fail = NULL;
    if (!s->usb_manager)
        fail = "USB manager unavailable";
    else if (!find_usb_device(s->usb_manager, op->device_id))
        fail = "Device not found";
    if (fail) {
        if (s->cb.usb_redirect_result)
            s->cb.usb_redirect_result(s->cb.ctx, op->device_id, 0, fail);
        g_free(op);
        return G_SOURCE_REMOVE;
    }
    SpiceUsbDevice *device = find_usb_device(s->usb_manager, op->device_id);
    if (op->connect) {
        spice_usb_device_manager_connect_device_async(s->usb_manager, device, NULL,
                                                      usb_redirect_done, op);
    } else {
        spice_usb_device_manager_disconnect_device_async(s->usb_manager, device, NULL,
                                                         usb_redirect_done, op);
    }
    return G_SOURCE_REMOVE;
}

/* ---- lifecycle (all session work happens on the runner thread) ---- */

static void apply_usb(VMMSpiceSession *s) {
    if (!s->session)
        return;
    detach_usb_signals(s);
    g_object_set(s->session, "enable-usbredir", s->usb_enabled ? TRUE : FALSE, NULL);
    if (!s->usb_enabled)
        return;
    GError *err = NULL;
    SpiceUsbDeviceManager *usb = spice_usb_device_manager_get(s->session, &err);
    if (err) {
        SHIMLOG("USB redirection unavailable: %s", err->message);
        g_clear_error(&err);
        return;
    }
    s->usb_manager = usb;
    s->usb_added_id = g_signal_connect(usb, "device-added", G_CALLBACK(on_usb_device_added), s);
    s->usb_removed_id = g_signal_connect(usb, "device-removed", G_CALLBACK(on_usb_device_removed), s);
    SHIMLOG("USB redirection enabled");
}

static gboolean usb_enable_cb(gpointer data) {
    apply_usb((VMMSpiceSession *)data);
    return G_SOURCE_REMOVE;
}

static void apply_audio(VMMSpiceSession *s) {
    if (!s->session)
        return;
    g_object_set(s->session, "enable-audio", s->audio_enabled ? TRUE : FALSE, NULL);
    if (s->audio_enabled) {
        SpiceAudio *audio = spice_audio_get(s->session, g_runner_ctx);
        SHIMLOG("audio %s (backend=%s)", audio ? "enabled" : "unavailable",
                audio ? "gstreamer" : "none");
    }
}

static gboolean audio_enable_cb(gpointer data) {
    VMMSpiceSession *s = data;
    apply_audio(s);
    return G_SOURCE_REMOVE;
}

static gboolean start_cb(gpointer data) {
    VMMSpiceSession *s = data;
    s->session = spice_session_new();
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", s->port);
    g_object_set(s->session, "host", s->host, "port", portstr, NULL);
    if (s->password)
        g_object_set(s->session, "password", s->password, NULL);

    g_signal_connect(s->session, "channel-new", G_CALLBACK(on_channel_new), s);
    g_signal_connect(s->session, "channel-destroy", G_CALLBACK(on_channel_destroy), s);

    apply_audio(s);
    apply_usb(s);

    SHIMLOG("connecting to %s:%d (password=%s audio=%s usb=%s)", s->host, s->port,
            s->password ? "yes" : "no", s->audio_enabled ? "on" : "off",
            s->usb_enabled ? "on" : "off");
    spice_session_connect(s->session);
    return G_SOURCE_REMOVE;
}

typedef struct { VMMSpiceSession *s; GMutex m; GCond c; int done; } StopOp;

/* Disconnect + free the session on the runner thread, then signal the caller. */
static gboolean stop_cb(gpointer data) {
    StopOp *op = data;
    VMMSpiceSession *s = op->s;
    if (s->session) {
        /* Sever every callback into `s` BEFORE disconnecting/unref'ing. Disconnecting
           a SPICE session schedules delayed channel unrefs that emit one last
           "channel-event" on the runner loop *after* this function returns — by which
           time the caller has freed `s`. Disconnecting the handlers here makes those
           late emissions harmless (no handler bound to the freed `s`). */
        GList *channels = spice_session_get_channels(s->session);
        for (GList *l = channels; l != NULL; l = l->next)
            g_signal_handlers_disconnect_by_data(l->data, s);
        g_list_free(channels);
        g_signal_handlers_disconnect_by_data(s->session, s);

        detach_usb_signals(s);
        spice_session_disconnect(s->session);
        g_object_unref(s->session);
        s->session = NULL;
    }
    if (s->clipboard_release_src) {
        g_source_remove(s->clipboard_release_src);
        s->clipboard_release_src = 0;
    }
    s->inputs = NULL; s->display = NULL; s->main_channel = NULL;
    s->host_clip_grabbed = 0;
    g_mutex_lock(&op->m);
    op->done = 1;
    g_cond_signal(&op->c);
    g_mutex_unlock(&op->m);
    return G_SOURCE_REMOVE;
}

/* ---- public API ---- */

VMMSpiceSession *vmm_spice_session_create(const char *host, int port,
                                          const char *password,
                                          VMMSpiceCallbacks callbacks) {
    VMMSpiceSession *s = calloc(1, sizeof(*s));
    s->host = g_strdup(host);
    s->port = port;
    s->password = (password && *password) ? g_strdup(password) : NULL;
    s->cb = callbacks;
    return s;
}

void vmm_spice_session_start(VMMSpiceSession *s) {
    if (!s || s->started) return;
    s->started = 1;
    ensure_runner();
    g_main_context_invoke(g_runner_ctx, start_cb, s);
}

void vmm_spice_session_stop(VMMSpiceSession *s) {
    if (!s) return;
    /* Tear the session down on the runner thread and block until it's done, so
       the caller can safely release the callback context afterwards. */
    if (s->started && g_runner_ctx) {
        StopOp op;
        op.s = s; op.done = 0;
        g_mutex_init(&op.m);
        g_cond_init(&op.c);
        g_main_context_invoke(g_runner_ctx, stop_cb, &op);
        g_mutex_lock(&op.m);
        while (!op.done) g_cond_wait(&op.c, &op.m);
        g_mutex_unlock(&op.m);
        g_mutex_clear(&op.m);
        g_cond_clear(&op.c);
    }
    g_free(s->host);
    g_free(s->password);
    free(s);
}

/* ---- input (marshalled onto the runner thread) ---- */

typedef struct {
    VMMSpiceSession *s;
    uint32_t scancode;
    int a, b, c, d;
} InputEvent;

static gboolean key_cb(gpointer data) {
    InputEvent *e = data;
    if (e->s->inputs) {
        if (e->a) spice_inputs_channel_key_press(e->s->inputs, e->scancode);
        else      spice_inputs_channel_key_release(e->s->inputs, e->scancode);
    }
    return G_SOURCE_REMOVE;
}

static gboolean motion_cb(gpointer data) {
    InputEvent *e = data;
    if (e->s->inputs)
        spice_inputs_channel_position(e->s->inputs, e->a, e->b, 0, e->c);
    return G_SOURCE_REMOVE;
}

static gboolean button_cb(gpointer data) {
    InputEvent *e = data;
    if (e->s->inputs) {
        if (e->c) spice_inputs_channel_button_press(e->s->inputs, e->a, e->b);
        else      spice_inputs_channel_button_release(e->s->inputs, e->a, e->b);
    }
    return G_SOURCE_REMOVE;
}

static gboolean wheel_cb(gpointer data) {
    InputEvent *e = data;
    if (e->s->inputs) {
        int button = e->a ? 4 : 5; /* SPICE_MOUSE_BUTTON_UP / _DOWN */
        spice_inputs_channel_button_press(e->s->inputs, button, e->b);
        spice_inputs_channel_button_release(e->s->inputs, button, e->b);
    }
    return G_SOURCE_REMOVE;
}

static void invoke(VMMSpiceSession *s, GSourceFunc fn, InputEvent ev) {
    if (!g_runner_ctx) return;
    InputEvent *e = g_new(InputEvent, 1);
    *e = ev; e->s = s;
    g_main_context_invoke_full(g_runner_ctx, G_PRIORITY_DEFAULT, fn, e, g_free);
}

void vmm_spice_key(VMMSpiceSession *s, uint32_t scancode, int down) {
    invoke(s, key_cb, (InputEvent){ .scancode = scancode, .a = down });
}

void vmm_spice_mouse_motion_abs(VMMSpiceSession *s, int x, int y, int button_mask) {
    invoke(s, motion_cb, (InputEvent){ .a = x, .b = y, .c = button_mask });
}

void vmm_spice_mouse_button(VMMSpiceSession *s, int button, int button_mask, int down) {
    invoke(s, button_cb, (InputEvent){ .a = button, .b = button_mask, .c = down });
}

void vmm_spice_mouse_wheel(VMMSpiceSession *s, int up, int button_mask) {
    invoke(s, wheel_cb, (InputEvent){ .a = up, .b = button_mask });
}

void vmm_spice_clipboard_enable(VMMSpiceSession *s, int enabled) {
    if (!s) return;
    s->clipboard_enabled = enabled ? 1 : 0;
    if (!enabled) s->host_clip_grabbed = 0;
}

void vmm_spice_clipboard_host_grab(VMMSpiceSession *s) {
    if (!s || !s->clipboard_enabled || !g_runner_ctx) return;
    g_main_context_invoke(g_runner_ctx, host_grab_cb, s);
}

void vmm_spice_usb_enable(VMMSpiceSession *s, int enabled) {
    if (!s)
        return;
    s->usb_enabled = enabled ? 1 : 0;
    if (s->started && g_runner_ctx)
        g_main_context_invoke(g_runner_ctx, usb_enable_cb, s);
}

int vmm_spice_usb_list_devices(VMMSpiceSession *s, VMMUsbDeviceInfo *out, int max_count) {
    if (!s || !s->started || !g_runner_ctx || !out || max_count <= 0)
        return 0;
    UsbListOp op;
    op.s = s;
    op.out = out;
    op.max_count = max_count;
    op.count = 0;
    op.done = 0;
    g_mutex_init(&op.m);
    g_cond_init(&op.c);
    g_main_context_invoke(g_runner_ctx, usb_list_cb, &op);
    g_mutex_lock(&op.m);
    while (!op.done)
        g_cond_wait(&op.c, &op.m);
    g_mutex_unlock(&op.m);
    g_mutex_clear(&op.m);
    g_cond_clear(&op.c);
    return op.count;
}

void vmm_spice_usb_connect(VMMSpiceSession *s, uint32_t device_id) {
    if (!s || !s->started || !g_runner_ctx)
        return;
    UsbRedirectOp *op = g_new0(UsbRedirectOp, 1);
    op->s = s;
    op->device_id = device_id;
    op->connect = 1;
    g_main_context_invoke(g_runner_ctx, usb_redirect_cb, op);
}

void vmm_spice_usb_disconnect(VMMSpiceSession *s, uint32_t device_id) {
    if (!s || !s->started || !g_runner_ctx)
        return;
    UsbRedirectOp *op = g_new0(UsbRedirectOp, 1);
    op->s = s;
    op->device_id = device_id;
    op->connect = 0;
    g_main_context_invoke(g_runner_ctx, usb_redirect_cb, op);
}

void vmm_spice_audio_enable(VMMSpiceSession *s, int enabled) {
    if (!s)
        return;
    s->audio_enabled = enabled ? 1 : 0;
    if (s->started && g_runner_ctx)
        g_main_context_invoke(g_runner_ctx, audio_enable_cb, s);
}

void vmm_spice_clipboard_host_notify(VMMSpiceSession *s, uint32_t type,
                                     const uint8_t *data, size_t size) {
    if (!s || !s->clipboard_enabled || !data || size == 0 || !g_runner_ctx) return;
    typedef struct { VMMSpiceSession *s; uint32_t type; GByteArray *bytes; } NotifyOp;
    NotifyOp *op = g_new0(NotifyOp, 1);
    op->s = s;
    op->type = type;
    op->bytes = g_byte_array_sized_new((guint)size);
    g_byte_array_append(op->bytes, data, (guint)size);
    g_main_context_invoke(g_runner_ctx, host_notify_cb, op);
}

#define VMM_SPICE_VER_STR2(x) #x
#define VMM_SPICE_VER_STR(x) VMM_SPICE_VER_STR2(x)

const char *vmm_spice_version(void) {
    static char buf[64];
    /* Stringify macros so git-dirty version tags like (42-dirty) still compile. */
    snprintf(buf, sizeof(buf), "spice-gtk %s.%s",
             VMM_SPICE_VER_STR(SPICE_GTK_MAJOR_VERSION),
             VMM_SPICE_VER_STR(SPICE_GTK_MINOR_VERSION));
    return buf;
}
