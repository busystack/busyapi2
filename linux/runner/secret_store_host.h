// Adapted from BusyMark's asynchronous libsecret bridge, Copyright 2026
// BusyStack (Apache-2.0). BusyAPI uses an independent schema and key policy.
#ifndef BUSYAPI_SECRET_STORE_HOST_H_
#define BUSYAPI_SECRET_STORE_HOST_H_

#include <flutter_linux/flutter_linux.h>

FlMethodChannel* busyapi_secret_store_channel_new(FlView* view);

#endif  // BUSYAPI_SECRET_STORE_HOST_H_
