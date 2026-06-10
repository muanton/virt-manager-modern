#ifndef VMM_CSPICE_UMBRELLA_H
#define VMM_CSPICE_UMBRELLA_H

/* Pulls in spice-client-glib and its glib/gobject dependencies. Only the C
   shim (`SpiceShim`) includes this; Swift never imports CSpice directly. */
#include <spice-client.h>

#endif /* VMM_CSPICE_UMBRELLA_H */
