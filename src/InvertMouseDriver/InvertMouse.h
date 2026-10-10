#pragma once

#include <ntddk.h>
#include <wdf.h>
#include <kbdmou.h>

#if DBG
#define DebugPrint(_x_) DbgPrint _x_
#else
#define DebugPrint(_x_)
#endif

#define NTDEVICE_NAME         L"\\Device\\invertmouse"
#define SYMBOLIC_NAME_STRING  L"\\DosDevices\\invertmouse"

// SYSTEM and Administrators have full access; authenticated local users
// can open the control device from the non-elevated InvertMouse app.
#define CONTROL_DEVICE_SDDL \
    L"D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GRGW;;;AU)"

#define IOCTL_INVERTMOUSE_GET_SETTINGS \
    CTL_CODE(FILE_DEVICE_MOUSE, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS)
#define IOCTL_INVERTMOUSE_SET_SETTINGS \
    CTL_CODE(FILE_DEVICE_MOUSE, 0x801, METHOD_BUFFERED, FILE_WRITE_ACCESS)
#define IOCTL_INVERTMOUSE_GET_VERSION \
    CTL_CODE(FILE_DEVICE_MOUSE, 0x802, METHOD_BUFFERED, FILE_READ_ACCESS)

constexpr int WRITE_DELAY_LONG = 1000;
constexpr int WRITE_DELAY_SHORT = 100;

typedef struct _INVERTMOUSE_SETTINGS {
    BOOLEAN enable;
    double multiplier_x;
    double multiplier_y;
} INVERTMOUSE_SETTINGS, * PINVERTMOUSE_SETTINGS;

typedef struct _DEVICE_EXTENSION {
    CONNECT_DATA UpperConnectData;
} DEVICE_EXTENSION, * PDEVICE_EXTENSION;

typedef struct _DRIVER_VERSION {
    int major;
    int minor;
    int patch;
} DRIVER_VERSION, * PDRIVER_VERSION;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_EXTENSION, FilterGetData)

EXTERN_C_START

DRIVER_INITIALIZE DriverEntry;

EVT_WDF_DRIVER_DEVICE_ADD EvtDeviceAdd;
EVT_WDF_DRIVER_UNLOAD InvertMouseUnload;
EVT_WDF_OBJECT_CONTEXT_CLEANUP EvtDeviceCleanup;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL EvtIoInternalDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL InvertMouseControl;

VOID InvertMouseInit(_In_ WDFDRIVER Driver);
NTSTATUS CreateControlDevice(_In_ WDFDRIVER Driver, _Out_ WDFDEVICE* ControlDevice);

VOID InvertMouseCallback(
    IN PDEVICE_OBJECT DeviceObject,
    IN PMOUSE_INPUT_DATA InputDataStart,
    IN PMOUSE_INPUT_DATA InputDataEnd,
    IN OUT PULONG InputDataConsumed
);

VOID WriteDelay(int delayMs);

VOID DispatchPassThrough(
    _In_ WDFREQUEST Request,
    _In_ WDFIOTARGET Target
);

EXTERN_C_END
