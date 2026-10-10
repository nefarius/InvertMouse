#include "InvertMouse.h"
#include "version.h"

#include <float.h>

#ifdef ALLOC_PRAGMA
#pragma alloc_text (INIT, DriverEntry)
#pragma alloc_text (INIT, InvertMouseInit)
#pragma alloc_text (INIT, CreateControlDevice)
#pragma alloc_text (PAGE, EvtDeviceAdd)
#pragma alloc_text (PAGE, InvertMouseUnload)
#endif

struct {
    BOOLEAN controlReady;
    WDFDEVICE controlDevice;
    WDFSPINLOCK settingsLock;
    INVERTMOUSE_SETTINGS settings;
} global = {};

extern "C" PULONG InitSafeBootMode;

static BOOLEAN
IsFiniteDouble(double value)
{
    return _finite(value) != 0;
}

static BOOLEAN
IsValidSettings(_In_ const INVERTMOUSE_SETTINGS* settings)
{
    return settings != NULL &&
        IsFiniteDouble(settings->multiplier_x) &&
        IsFiniteDouble(settings->multiplier_y);
}

static LONG
ScaleLong(LONG value, double multiplier)
{
    double scaled = static_cast<double>(value) * multiplier;

    if (!IsFiniteDouble(scaled)) {
        return 0;
    }
    if (scaled >= static_cast<double>(MAXLONG)) {
        return MAXLONG;
    }
    if (scaled <= static_cast<double>(MINLONG)) {
        return MINLONG;
    }

    return static_cast<LONG>(scaled);
}

_Success_(return != FALSE)
static BOOLEAN
CopySettings(_Out_ INVERTMOUSE_SETTINGS* outSettings)
{
    if (outSettings == NULL) {
        return FALSE;
    }

    RtlZeroMemory(outSettings, sizeof(*outSettings));

    if (global.settingsLock == NULL) {
        return FALSE;
    }

    WdfSpinLockAcquire(global.settingsLock);
    *outSettings = global.settings;
    WdfSpinLockRelease(global.settingsLock);
    return TRUE;
}

static VOID
StoreSettings(_In_ const INVERTMOUSE_SETTINGS* settings)
{
    if (settings == NULL || global.settingsLock == NULL) {
        return;
    }

    WdfSpinLockAcquire(global.settingsLock);
    global.settings = *settings;
    WdfSpinLockRelease(global.settingsLock);
}

VOID
InvertMouseCallback(
    IN PDEVICE_OBJECT DeviceObject,
    IN PMOUSE_INPUT_DATA InputDataStart,
    IN PMOUSE_INPUT_DATA InputDataEnd,
    IN OUT PULONG InputDataConsumed
)
{
    WDFDEVICE hDevice = WdfWdmDeviceGetWdfDeviceHandle(DeviceObject);
    PDEVICE_EXTENSION devExt = FilterGetData(hDevice);
    INVERTMOUSE_SETTINGS settings = {};

    if (CopySettings(&settings) && settings.enable) {
        for (PMOUSE_INPUT_DATA it = InputDataStart; it != InputDataEnd; ++it) {
            if ((it->Flags & MOUSE_MOVE_ABSOLUTE) != 0) {
                continue;
            }
            if (it->LastX == 0 && it->LastY == 0) {
                continue;
            }

            it->LastX = ScaleLong(it->LastX, settings.multiplier_x);
            it->LastY = ScaleLong(it->LastY, settings.multiplier_y);
        }
    }

    (*(PSERVICE_CALLBACK_ROUTINE)devExt->UpperConnectData.ClassService)(
        devExt->UpperConnectData.ClassDeviceObject,
        InputDataStart,
        InputDataEnd,
        InputDataConsumed
        );
}

VOID
WriteDelay(int delayMs)
{
    LARGE_INTEGER interval;

    if (delayMs <= 0) {
        return;
    }

    interval.QuadPart = -10000LL * delayMs;
    KeDelayExecutionThread(KernelMode, FALSE, &interval);
}

_Use_decl_annotations_
VOID
InvertMouseControl(
    WDFQUEUE         Queue,
    WDFREQUEST       Request,
    size_t           OutputBufferLength,
    size_t           InputBufferLength,
    ULONG            IoControlCode
)
{
    UNREFERENCED_PARAMETER(Queue);
    UNREFERENCED_PARAMETER(InputBufferLength);
    UNREFERENCED_PARAMETER(OutputBufferLength);

    DebugPrint(("InvertMouse: Ioctl received into filter control object.\n"));

    if (!global.controlReady) {
        WdfRequestCompleteWithInformation(Request, STATUS_DEVICE_NOT_READY, 0);
        return;
    }

    NTSTATUS status = STATUS_SUCCESS;
    size_t bytes_out = 0;

    switch (IoControlCode) {
    case IOCTL_INVERTMOUSE_GET_SETTINGS: {
        PINVERTMOUSE_SETTINGS out;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(INVERTMOUSE_SETTINGS), (PVOID*)&out, NULL);
        if (NT_SUCCESS(status)) {
            if (!CopySettings(out)) {
                status = STATUS_DEVICE_NOT_READY;
            }
            else {
                bytes_out = sizeof(INVERTMOUSE_SETTINGS);
            }
        }
        break;
    }
    case IOCTL_INVERTMOUSE_SET_SETTINGS: {
        PINVERTMOUSE_SETTINGS in;
        INVERTMOUSE_SETTINGS current = {};
        int delayMs = WRITE_DELAY_LONG;

        status = WdfRequestRetrieveInputBuffer(Request, sizeof(INVERTMOUSE_SETTINGS), (PVOID*)&in, NULL);
        if (!NT_SUCCESS(status)) {
            break;
        }
        if (!IsValidSettings(in)) {
            status = STATUS_INVALID_PARAMETER;
            break;
        }

        if (CopySettings(&current) &&
            in->multiplier_x == current.multiplier_x &&
            in->multiplier_y == current.multiplier_y)
        {
            delayMs = WRITE_DELAY_SHORT;
        }

        StoreSettings(in);
        WriteDelay(delayMs);
        break;
    }
    case IOCTL_INVERTMOUSE_GET_VERSION: {
        PDRIVER_VERSION out;
        status = WdfRequestRetrieveOutputBuffer(Request, sizeof(DRIVER_VERSION), (PVOID*)&out, NULL);
        if (NT_SUCCESS(status)) {
            *out = { VERSION };
            bytes_out = sizeof(DRIVER_VERSION);
        }
        break;
    }
    default:
        status = STATUS_INVALID_DEVICE_REQUEST;
        break;
    }

    WdfRequestCompleteWithInformation(Request, status, bytes_out);
}

NTSTATUS
CreateControlDevice(
    _In_ WDFDRIVER Driver,
    _Out_ WDFDEVICE* ControlDevice
)
{
    PWDFDEVICE_INIT             pInit = NULL;
    WDFDEVICE                   controlDevice = NULL;
    WDF_IO_QUEUE_CONFIG         ioQueueConfig;
    NTSTATUS                    status;
    WDFQUEUE                    queue;
    DECLARE_CONST_UNICODE_STRING(ntDeviceName, NTDEVICE_NAME);
    DECLARE_CONST_UNICODE_STRING(symbolicLinkName, SYMBOLIC_NAME_STRING);
    DECLARE_CONST_UNICODE_STRING(sddl, CONTROL_DEVICE_SDDL);

    *ControlDevice = NULL;

    DebugPrint(("InvertMouse: Creating Control Device\n"));

    pInit = WdfControlDeviceInitAllocate(Driver, &sddl);
    if (pInit == NULL) {
        status = STATUS_INSUFFICIENT_RESOURCES;
        goto Error;
    }

    WdfDeviceInitSetExclusive(pInit, FALSE);
    WdfDeviceInitSetCharacteristics(pInit, FILE_DEVICE_SECURE_OPEN, TRUE);

    status = WdfDeviceInitAssignName(pInit, &ntDeviceName);
    if (!NT_SUCCESS(status)) {
        goto Error;
    }

    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    WDF_OBJECT_ATTRIBUTES_INIT(&deviceAttributes);
    deviceAttributes.ExecutionLevel = WdfExecutionLevelPassive;

    status = WdfDeviceCreate(&pInit,
        &deviceAttributes,
        &controlDevice);
    if (!NT_SUCCESS(status)) {
        goto Error;
    }

    status = WdfDeviceCreateSymbolicLink(controlDevice, &symbolicLinkName);
    if (!NT_SUCCESS(status)) {
        goto Error;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&ioQueueConfig,
        WdfIoQueueDispatchSequential);

    ioQueueConfig.EvtIoDeviceControl = InvertMouseControl;

    status = WdfIoQueueCreate(controlDevice,
        &ioQueueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        &queue);
    if (!NT_SUCCESS(status)) {
        goto Error;
    }

    WdfControlFinishInitializing(controlDevice);
    *ControlDevice = controlDevice;
    return STATUS_SUCCESS;

Error:
    if (pInit != NULL) {
        WdfDeviceInitFree(pInit);
    }

    if (controlDevice != NULL) {
        WdfObjectDelete(controlDevice);
    }

    DebugPrint(("InvertMouse: CreateControlDevice failed with status code 0x%x\n", status));
    return status;
}

NTSTATUS
DriverEntry(
    IN  PDRIVER_OBJECT  DriverObject,
    IN  PUNICODE_STRING RegistryPath
)
{
    WDF_DRIVER_CONFIG config;
    NTSTATUS status;
    WDFDRIVER driver;

    DebugPrint(("InvertMouse: DriverEntry.\n"));
    DebugPrint(("InvertMouse: Built %s %s\n", __DATE__, __TIME__));

    WDF_DRIVER_CONFIG_INIT(&config, EvtDeviceAdd);
    config.EvtDriverUnload = InvertMouseUnload;

    status = WdfDriverCreate(DriverObject,
        RegistryPath,
        WDF_NO_OBJECT_ATTRIBUTES,
        &config,
        &driver);

    if (NT_SUCCESS(status)) {
        InvertMouseInit(driver);
    }
    else {
        DebugPrint(("InvertMouse: WdfDriverCreate failed with status 0x%x\n", status));
    }

    return status;
}

VOID
InvertMouseInit(_In_ WDFDRIVER driver)
{
    WDF_OBJECT_ATTRIBUTES attributes;
    NTSTATUS status;
    INVERTMOUSE_SETTINGS defaults = {};

    defaults.enable = FALSE;
    defaults.multiplier_x = 1.0;
    defaults.multiplier_y = 1.0;

    WDF_OBJECT_ATTRIBUTES_INIT(&attributes);
    attributes.ParentObject = driver;

    status = WdfSpinLockCreate(&attributes, &global.settingsLock);
    if (!NT_SUCCESS(status)) {
        DebugPrint(("InvertMouse: WdfSpinLockCreate failed with status 0x%x\n", status));
        global.settingsLock = NULL;
        return;
    }

    StoreSettings(&defaults);

    if (*InitSafeBootMode != 0) {
        DebugPrint(("InvertMouse: Safe boot; control device not created\n"));
        return;
    }

    status = CreateControlDevice(driver, &global.controlDevice);
    if (!NT_SUCCESS(status)) {
        DebugPrint(("InvertMouse: CreateControlDevice failed with status 0x%x\n", status));
        global.controlDevice = NULL;
        return;
    }

    global.controlReady = TRUE;
}

VOID
InvertMouseUnload(_In_ WDFDRIVER Driver)
{
    UNREFERENCED_PARAMETER(Driver);
    PAGED_CODE();

    global.controlReady = FALSE;

    if (global.controlDevice != NULL) {
        WdfObjectDelete(global.controlDevice);
        global.controlDevice = NULL;
    }
}

VOID
EvtDeviceCleanup(_In_ WDFOBJECT Object)
{
    PDEVICE_EXTENSION devExt = FilterGetData((WDFDEVICE)Object);
    devExt->UpperConnectData.ClassService = NULL;
    devExt->UpperConnectData.ClassDeviceObject = NULL;
}

NTSTATUS
EvtDeviceAdd(
    IN WDFDRIVER        Driver,
    IN PWDFDEVICE_INIT  DeviceInit
)
{
    WDF_OBJECT_ATTRIBUTES deviceAttributes;
    NTSTATUS status;
    WDFDEVICE hDevice;
    WDF_IO_QUEUE_CONFIG ioQueueConfig;

    UNREFERENCED_PARAMETER(Driver);

    PAGED_CODE();

    DebugPrint(("InvertMouse: Enter EvtDeviceAdd\n"));

    WdfFdoInitSetFilter(DeviceInit);
    WdfDeviceInitSetDeviceType(DeviceInit, FILE_DEVICE_MOUSE);

    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&deviceAttributes, DEVICE_EXTENSION);
    deviceAttributes.EvtCleanupCallback = EvtDeviceCleanup;

    status = WdfDeviceCreate(&DeviceInit, &deviceAttributes, &hDevice);
    if (!NT_SUCCESS(status)) {
        DebugPrint(("InvertMouse: WdfDeviceCreate failed with status code 0x%x\n", status));
        return status;
    }

    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&ioQueueConfig, WdfIoQueueDispatchParallel);
    ioQueueConfig.EvtIoInternalDeviceControl = EvtIoInternalDeviceControl;

    status = WdfIoQueueCreate(hDevice,
        &ioQueueConfig,
        WDF_NO_OBJECT_ATTRIBUTES,
        WDF_NO_HANDLE);
    if (!NT_SUCCESS(status)) {
        DebugPrint(("InvertMouse: WdfIoQueueCreate failed 0x%x\n", status));
        return status;
    }

    DebugPrint(("InvertMouse: EvtDeviceAdd finished\n"));
    return status;
}

VOID
EvtIoInternalDeviceControl(
    IN WDFQUEUE      Queue,
    IN WDFREQUEST    Request,
    IN size_t        OutputBufferLength,
    IN size_t        InputBufferLength,
    IN ULONG         IoControlCode
)
{
    PDEVICE_EXTENSION devExt;
    PCONNECT_DATA connectData;
    NTSTATUS status = STATUS_SUCCESS;
    WDFDEVICE hDevice;
    size_t length;

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    DebugPrint(("InvertMouse: Enter EvtIoInternalDeviceControl\n"));

    hDevice = WdfIoQueueGetDevice(Queue);
    devExt = FilterGetData(hDevice);

    switch (IoControlCode) {
    case IOCTL_INTERNAL_MOUSE_CONNECT: {
        DebugPrint(("InvertMouse: CONNECT\n"));

        if (devExt->UpperConnectData.ClassService != NULL) {
            DebugPrint(("InvertMouse: SHARING\n"));
            status = STATUS_SHARING_VIOLATION;
            break;
        }

        status = WdfRequestRetrieveInputBuffer(Request, sizeof(CONNECT_DATA),
            reinterpret_cast<PVOID*>(&connectData), &length);
        if (!NT_SUCCESS(status)) {
            DebugPrint(("InvertMouse: WdfRequestRetrieveInputBuffer failed %x\n", status));
            break;
        }

        devExt->UpperConnectData = *connectData;
        connectData->ClassDeviceObject = WdfDeviceWdmGetDeviceObject(hDevice);
        connectData->ClassService = InvertMouseCallback;

        DebugPrint(("InvertMouse: CONNECT finished\n"));
        break;
    }
    case IOCTL_INTERNAL_MOUSE_DISCONNECT:
        // Moufiltr contract: this request is completed with STATUS_NOT_IMPLEMENTED.
        status = STATUS_NOT_IMPLEMENTED;
        break;
    default:
        break;
    }

    if (!NT_SUCCESS(status)) {
        WdfRequestComplete(Request, status);
        return;
    }

    DispatchPassThrough(Request, WdfDeviceGetIoTarget(hDevice));
}

VOID
DispatchPassThrough(
    _In_ WDFREQUEST Request,
    _In_ WDFIOTARGET Target
)
{
    WDF_REQUEST_SEND_OPTIONS options;
    BOOLEAN ret;
    NTSTATUS status = STATUS_SUCCESS;

    WDF_REQUEST_SEND_OPTIONS_INIT(&options,
        WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);

    ret = WdfRequestSend(Request, Target, &options);

    if (ret == FALSE) {
        status = WdfRequestGetStatus(Request);
        DebugPrint(("InvertMouse: WdfRequestSend failed: 0x%x\n", status));
        WdfRequestComplete(Request, status);
    }
}
