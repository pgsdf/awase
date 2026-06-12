/*
 * hid_if.h shim for the AD-9 fuzz harness.
 *
 * The kernel build normally generates this header from
 * /usr/src/sys/dev/hid/hid_if.m via
 * `awk -f /usr/src/sys/tools/makeobjops.awk`. The generated
 * header provides eleven kobj-method-dispatch macros that
 * hid.c's wrapper functions (lines 1036-1102) expand into
 * device-tree calls. The harness never invokes those wrapper
 * functions, but they must compile, so this shim provides
 * stub macros that evaluate the arguments and return 0
 * (or void) without dispatching anywhere.
 *
 * Each macro takes (parent, dev) as the first two arguments
 * (the kobj source and the device we're calling into); some
 * methods take additional payload arguments. The stub
 * evaluates each argument exactly once via comma operator
 * and discards the result, then yields 0 for int-returning
 * methods or nothing for void-returning methods.
 */

#ifndef _SHIM_HID_IF_H_
#define _SHIM_HID_IF_H_

/* int-returning methods */
#define HID_INTR_START(parent, dev) \
	((void)(parent), (void)(dev), 0)

#define HID_INTR_STOP(parent, dev) \
	((void)(parent), (void)(dev), 0)

#define HID_GET_RDESC(parent, dev, data, len) \
	((void)(parent), (void)(dev), (void)(data), (void)(len), 0)

#define HID_READ(parent, dev, data, maxlen, actlen) \
	((void)(parent), (void)(dev), (void)(data), (void)(maxlen), (void)(actlen), 0)

#define HID_WRITE(parent, dev, data, len) \
	((void)(parent), (void)(dev), (void)(data), (void)(len), 0)

#define HID_GET_REPORT(parent, dev, data, maxlen, actlen, type, id) \
	((void)(parent), (void)(dev), (void)(data), (void)(maxlen), \
	 (void)(actlen), (void)(type), (void)(id), 0)

#define HID_SET_REPORT(parent, dev, data, len, type, id) \
	((void)(parent), (void)(dev), (void)(data), (void)(len), \
	 (void)(type), (void)(id), 0)

#define HID_SET_IDLE(parent, dev, duration, id) \
	((void)(parent), (void)(dev), (void)(duration), (void)(id), 0)

#define HID_SET_PROTOCOL(parent, dev, protocol) \
	((void)(parent), (void)(dev), (void)(protocol), 0)

#define HID_IOCTL(parent, dev, cmd, data) \
	((void)(parent), (void)(dev), (void)(cmd), (void)(data), 0)

/* void-returning method */
#define HID_INTR_POLL(parent, dev) \
	do { (void)(parent); (void)(dev); } while (0)

#endif /* _SHIM_HID_IF_H_ */
