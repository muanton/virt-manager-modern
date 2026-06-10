#include "spice_shim.h"

#include <spice-client.h>
#include <glib.h>
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

/* ---- lifecycle (all session work happens on the runner thread) ---- */

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

    SHIMLOG("connecting to %s:%d (password=%s)", s->host, s->port, s->password ? "yes" : "no");
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

        spice_session_disconnect(s->session);
        g_object_unref(s->session);
        s->session = NULL;
    }
    s->inputs = NULL; s->display = NULL; s->main_channel = NULL;
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

const char *vmm_spice_version(void) {
    static char buf[64];
    snprintf(buf, sizeof(buf), "spice-gtk %d.%d",
             SPICE_GTK_MAJOR_VERSION, SPICE_GTK_MINOR_VERSION);
    return buf;
}
