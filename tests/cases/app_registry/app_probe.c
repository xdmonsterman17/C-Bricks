#include <stdio.h>
#include <string.h>
#include "cbricks.h"
#include "app_probe.h"

/* The app registry: nothing found before, found after cb_register_app, and a deleted program is not found. */
int app_probe(void) {
    const char *dir = cb_config_dir();
    char path[1300];
    const char *found;
    int before, registered, after, same, stale;
    printf("config set %d\n", *dir ? 1 : 0);
    before = *cb_find_app("probe-app") == 0;
    registered = cb_register_app("probe-app") ? 1 : 0;
    found = cb_find_app("probe-app");
    after = *found != 0;
    same = strcmp(found, cb_exe_path()) == 0;
    /* an entry that points at a missing file */
    snprintf(path, sizeof path, "%s/apps/ghost-app", dir);
    cb_write_file(path, "/no/such/program", false);
    stale = *cb_find_app("ghost-app") == 0;
    printf("before %d, registered %d, after %d, same %d, stale %d\n", before, registered, after, same, stale);
    return 0;
}
