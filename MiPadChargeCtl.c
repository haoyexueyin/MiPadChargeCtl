#include <ntifs.h>
#include <wdmsec.h>
#include <acpiioct.h>
#include <initguid.h>
#include <batclass.h>

/*
 * MiPadChargeCtl.sys
 * Xiaomi Mi Pad 2 / Windows 10
 *
 * Safety design:
 *   - Does not expose arbitrary I2C or arbitrary-register writes.
 *   - GET only reads BQ25890 REG03 through BATC.GETC(0x03).
 *   - SET only changes REG03 bit 4 (CHG_CONFIG) after a read-modify-write.
 *   - Reads REG03 again after SETC to verify the requested state.
 *
 * The driver is a small legacy control driver. It does NOT install as a
 * Battery upper/lower filter and does NOT replace Microsoft's battery driver.
 */

#define DEVICE_NAME      L"\\Device\\MiPadChargeCtl"
#define DOS_DEVICE_NAME  L"\\DosDevices\\MiPadChargeCtl"

#define IOCTL_MIPAD_GET_STATE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_BUFFERED, FILE_READ_ACCESS)

#define IOCTL_MIPAD_SET_CHARGE \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x802, METHOD_BUFFERED, \
             FILE_READ_ACCESS | FILE_WRITE_ACCESS)

#define IOCTL_MIPAD_GET_DIAGNOSTICS \
    CTL_CODE(FILE_DEVICE_UNKNOWN, 0x803, METHOD_BUFFERED, FILE_READ_ACCESS)

#define BQ25890_REG03             0x03u
#define BQ25890_REG03_CHG_CONFIG  0x10u
#define BQ25890_REG0B             0x0Bu
#define BQ25890_REG11             0x11u
#define BQ25890_REG12             0x12u
#define BQ25890_REG13             0x13u
#define BQ25890_REG14             0x14u

typedef struct _MIPAD_CHARGE_STATE {
    ULONG Version;
    ULONG Reg03;
    ULONG ChargeEnabled;
    ULONG WritesEnabled;
    ULONG Changed;
} MIPAD_CHARGE_STATE, *PMIPAD_CHARGE_STATE;

typedef struct _MIPAD_SET_REQUEST {
    ULONG Version;
    ULONG Enable; /* 0 = disable charging, 1 = enable charging */
} MIPAD_SET_REQUEST, *PMIPAD_SET_REQUEST;

typedef struct _MIPAD_DIAGNOSTICS {
    ULONG Version;
    ULONG Reg03;
    ULONG Reg0B;
    ULONG Reg11;
    ULONG Reg12;
    ULONG Reg13;
    ULONG Reg14;
} MIPAD_DIAGNOSTICS, *PMIPAD_DIAGNOSTICS;

#define MIPAD_PROTOCOL_VERSION 1u

/* {5596A14B-4E7D-42A9-B5F1-573899257DEC} */
DEFINE_GUID(GUID_DEVCLASS_MIPAD_CHARGE_CTL,
    0x5596a14b, 0x4e7d, 0x42a9,
    0xb5, 0xf1, 0x57, 0x38, 0x99, 0x25, 0x7d, 0xec);

static KMUTEX gAcpiMutex;
static BOOLEAN gWritesEnabled = FALSE;

static
NTSTATUS
AcpiGetRegister(
    _In_ PDEVICE_OBJECT Pdo,
    _In_ ULONG Register,
    _Out_ PULONG Value
);

_Dispatch_type_(IRP_MJ_CREATE)
_Dispatch_type_(IRP_MJ_CLEANUP)
_Dispatch_type_(IRP_MJ_CLOSE)
DRIVER_DISPATCH DispatchCreateClose;

_Dispatch_type_(IRP_MJ_DEVICE_CONTROL)
DRIVER_DISPATCH DispatchDeviceControl;

DRIVER_UNLOAD DriverUnload;
DRIVER_INITIALIZE DriverEntry;

static
BOOLEAN
IsExpectedBatteryPdo(
    _In_ PDEVICE_OBJECT Pdo
)
{
    WCHAR hardwareIds[128];
    ULONG requiredSize = 0;
    NTSTATUS status;
    PWSTR currentId;
    UNICODE_STRING actualId;
    UNICODE_STRING expectedId = RTL_CONSTANT_STRING(L"ACPI\\PNP0C0A");

    RtlZeroMemory(hardwareIds, sizeof(hardwareIds));
    status = IoGetDeviceProperty(
        Pdo,
        DevicePropertyHardwareID,
        sizeof(hardwareIds),
        hardwareIds,
        &requiredSize
    );

    if (!NT_SUCCESS(status) || requiredSize < (2 * sizeof(WCHAR)) ||
        requiredSize > sizeof(hardwareIds)) {
        return FALSE;
    }

    hardwareIds[(sizeof(hardwareIds) / sizeof(WCHAR)) - 1] = L'\0';
    for (currentId = hardwareIds; *currentId != L'\0';
         currentId += (actualId.Length / sizeof(WCHAR)) + 1) {
        RtlInitUnicodeString(&actualId, currentId);
        if (RtlEqualUnicodeString(&actualId, &expectedId, TRUE)) {
            return TRUE;
        }
    }

    return FALSE;
}

static
NTSTATUS
CompleteIrp(
    _Inout_ PIRP Irp,
    _In_ NTSTATUS Status,
    _In_ ULONG_PTR Information
)
{
    Irp->IoStatus.Status = Status;
    Irp->IoStatus.Information = Information;
    IoCompleteRequest(Irp, IO_NO_INCREMENT);
    return Status;
}

static
NTSTATUS
FindBatteryPdo(
    _Outptr_ PDEVICE_OBJECT *Pdo,
    _Out_ PULONG InitialReg03
)
{
    NTSTATUS status;
    PWSTR symbolicLinks = NULL;
    PWSTR currentLink;
    UNICODE_STRING interfaceName;
    NTSTATUS lastProbeStatus = STATUS_NOT_FOUND;
    PDEVICE_OBJECT matchedPdo = NULL;
    ULONG matchedReg03 = 0;

    *Pdo = NULL;
    *InitialReg03 = 0;

    status = IoGetDeviceInterfaces(
        &GUID_DEVICE_BATTERY,
        NULL,
        0,
        &symbolicLinks
    );

    if (!NT_SUCCESS(status)) {
        return status;
    }

    if (symbolicLinks == NULL || symbolicLinks[0] == L'\0') {
        if (symbolicLinks != NULL) {
            ExFreePool(symbolicLinks);
        }
        return STATUS_NOT_FOUND;
    }

    for (currentLink = symbolicLinks;
         *currentLink != L'\0';
         currentLink += (interfaceName.Length / sizeof(WCHAR)) + 1) {
        PFILE_OBJECT fileObject = NULL;
        PDEVICE_OBJECT topDevice = NULL;
        PDEVICE_OBJECT baseDevice = NULL;
        ULONG reg03 = 0;

        RtlInitUnicodeString(&interfaceName, currentLink);
        status = IoGetDeviceObjectPointer(
            &interfaceName,
            FILE_READ_ATTRIBUTES,
            &fileObject,
            &topDevice
        );

        if (NT_SUCCESS(status)) {
            /*
             * Probe each battery-class interface. Some systems expose more
             * than one; only the Mi Pad BATC PDO implements GETC.
             */
            baseDevice = IoGetDeviceAttachmentBaseRef(topDevice);
            if (baseDevice != NULL) {
                if (!IsExpectedBatteryPdo(baseDevice)) {
                    ObDereferenceObject(baseDevice);
                    baseDevice = NULL;
                    lastProbeStatus = STATUS_DEVICE_HARDWARE_ERROR;
                }
            }

            if (baseDevice != NULL) {
                lastProbeStatus = AcpiGetRegister(
                    baseDevice,
                    BQ25890_REG03,
                    &reg03
                );

                if (NT_SUCCESS(lastProbeStatus)) {
                    if (matchedPdo != NULL) {
                        /* More than one writable-looking target is unsafe. */
                        ObDereferenceObject(baseDevice);
                        ObDereferenceObject(fileObject);
                        ObDereferenceObject(matchedPdo);
                        ExFreePool(symbolicLinks);
                        return STATUS_OBJECT_NAME_COLLISION;
                    }

                    matchedPdo = baseDevice;
                    matchedReg03 = reg03;
                    baseDevice = NULL;
                }

                if (baseDevice != NULL) {
                    ObDereferenceObject(baseDevice);
                }
            } else {
                lastProbeStatus = STATUS_NO_SUCH_DEVICE;
            }
        } else {
            lastProbeStatus = status;
        }

        if (fileObject != NULL) {
            ObDereferenceObject(fileObject);
        }
    }

    ExFreePool(symbolicLinks);

    if (matchedPdo != NULL) {
        *Pdo = matchedPdo;
        *InitialReg03 = matchedReg03;
        return STATUS_SUCCESS;
    }

    return lastProbeStatus;
}

static
NTSTATUS
SendAcpiIoctl(
    _In_ PDEVICE_OBJECT Pdo,
    _In_ ULONG IoControlCode,
    _In_reads_bytes_(InputLength) PVOID InputBuffer,
    _In_ ULONG InputLength,
    _Out_writes_bytes_(OutputLength) PVOID OutputBuffer,
    _In_ ULONG OutputLength,
    _Out_opt_ PULONG_PTR BytesReturned
)
{
    KEVENT event;
    IO_STATUS_BLOCK ioStatus;
    PIRP irp;
    NTSTATUS status;

    KeInitializeEvent(&event, NotificationEvent, FALSE);
    RtlZeroMemory(&ioStatus, sizeof(ioStatus));

    irp = IoBuildDeviceIoControlRequest(
        IoControlCode,
        Pdo,
        InputBuffer,
        InputLength,
        OutputBuffer,
        OutputLength,
        FALSE,
        &event,
        &ioStatus
    );

    if (irp == NULL) {
        return STATUS_INSUFFICIENT_RESOURCES;
    }

    status = IoCallDriver(Pdo, irp);

    if (status == STATUS_PENDING) {
        KeWaitForSingleObject(
            &event,
            Executive,
            KernelMode,
            FALSE,
            NULL
        );
        status = ioStatus.Status;
    }

    if (BytesReturned != NULL) {
        *BytesReturned = ioStatus.Information;
    }

    return status;
}

static
NTSTATUS
AcpiGetRegister(
    _In_ PDEVICE_OBJECT Pdo,
    _In_ ULONG Register,
    _Out_ PULONG Value
)
{
    ACPI_EVAL_INPUT_BUFFER_SIMPLE_INTEGER input;
    UCHAR outputRaw[256];
    PACPI_EVAL_OUTPUT_BUFFER output;
    PACPI_METHOD_ARGUMENT argument;
    ULONG_PTR bytesReturned = 0;
    NTSTATUS status;

    RtlZeroMemory(&input, sizeof(input));
    RtlZeroMemory(outputRaw, sizeof(outputRaw));

    input.Signature = ACPI_EVAL_INPUT_BUFFER_SIMPLE_INTEGER_SIGNATURE;

    /*
     * MethodNameAsUlong must contain bytes "GETC" in memory.
     * 0x43544547 = G E T C on little-endian x86/x64.
     */
    input.MethodNameAsUlong = 0x43544547u;
    input.IntegerArgument = Register;

    status = SendAcpiIoctl(
        Pdo,
        IOCTL_ACPI_EVAL_METHOD,
        &input,
        sizeof(input),
        outputRaw,
        sizeof(outputRaw),
        &bytesReturned
    );

    if (!NT_SUCCESS(status)) {
        return status;
    }

    if (bytesReturned < FIELD_OFFSET(ACPI_EVAL_OUTPUT_BUFFER, Argument) +
                        ACPI_METHOD_ARGUMENT_LENGTH(sizeof(ULONG))) {
        return STATUS_INFO_LENGTH_MISMATCH;
    }

    output = (PACPI_EVAL_OUTPUT_BUFFER)outputRaw;

    if (output->Signature != ACPI_EVAL_OUTPUT_BUFFER_SIGNATURE ||
        output->Count < 1 ||
        output->Length > bytesReturned ||
        output->Length < FIELD_OFFSET(ACPI_EVAL_OUTPUT_BUFFER, Argument) +
                         ACPI_METHOD_ARGUMENT_LENGTH(sizeof(ULONG))) {
        return STATUS_ACPI_INVALID_DATA;
    }

    argument = &output->Argument[0];

    if (argument->Type != ACPI_METHOD_ARGUMENT_INTEGER ||
        argument->DataLength < sizeof(ULONG)) {
        return STATUS_ACPI_INVALID_ARGTYPE;
    }

    if (argument->Argument > 0xFFu) {
        return STATUS_DEVICE_PROTOCOL_ERROR;
    }

    *Value = argument->Argument;
    return STATUS_SUCCESS;
}

static
NTSTATUS
AcpiSetRegister(
    _In_ PDEVICE_OBJECT Pdo,
    _In_ ULONG Register,
    _In_ ULONG Value
)
{
    UCHAR inputRaw[
        FIELD_OFFSET(ACPI_EVAL_INPUT_BUFFER_COMPLEX, Argument) +
        (2 * ACPI_METHOD_ARGUMENT_LENGTH(sizeof(ULONG)))
    ];
    UCHAR outputRaw[256];

    PACPI_EVAL_INPUT_BUFFER_COMPLEX input;
    PACPI_METHOD_ARGUMENT argument;
    ULONG argumentBytes;
    ULONG inputBytes;
    ULONG_PTR bytesReturned = 0;

    RtlZeroMemory(inputRaw, sizeof(inputRaw));
    RtlZeroMemory(outputRaw, sizeof(outputRaw));

    input = (PACPI_EVAL_INPUT_BUFFER_COMPLEX)inputRaw;

    argumentBytes = 2 * ACPI_METHOD_ARGUMENT_LENGTH(sizeof(ULONG));
    inputBytes = FIELD_OFFSET(ACPI_EVAL_INPUT_BUFFER_COMPLEX, Argument) +
                 argumentBytes;

    input->Signature = ACPI_EVAL_INPUT_BUFFER_COMPLEX_SIGNATURE;

    /*
     * Bytes "SETC" in memory.
     * 0x43544553 = S E T C on little-endian x86/x64.
     */
    input->MethodNameAsUlong = 0x43544553u;
    input->Size = argumentBytes;
    input->ArgumentCount = 2;

    argument = &input->Argument[0];
    ACPI_METHOD_SET_ARGUMENT_INTEGER(argument, Register);

    argument = ACPI_METHOD_NEXT_ARGUMENT(argument);
    ACPI_METHOD_SET_ARGUMENT_INTEGER(argument, Value);

    return SendAcpiIoctl(
        Pdo,
        IOCTL_ACPI_EVAL_METHOD,
        input,
        inputBytes,
        outputRaw,
        sizeof(outputRaw),
        &bytesReturned
    );
}

static
NTSTATUS
ReadChargeState(
    _Out_ PMIPAD_CHARGE_STATE State
)
{
    PDEVICE_OBJECT pdo = NULL;
    NTSTATUS status;
    ULONG reg03 = 0;

    RtlZeroMemory(State, sizeof(*State));

    status = FindBatteryPdo(&pdo, &reg03);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    ObDereferenceObject(pdo);

    State->Version = MIPAD_PROTOCOL_VERSION;
    State->Reg03 = reg03 & 0xFFu;
    State->ChargeEnabled =
        ((reg03 & BQ25890_REG03_CHG_CONFIG) != 0) ? 1u : 0u;
    State->WritesEnabled = gWritesEnabled ? 1u : 0u;
    State->Changed = 0u;

    return STATUS_SUCCESS;
}

static
NTSTATUS
ReadDiagnostics(
    _Out_ PMIPAD_DIAGNOSTICS Diagnostics
)
{
    PDEVICE_OBJECT pdo = NULL;
    NTSTATUS status;
    ULONG value = 0;

    RtlZeroMemory(Diagnostics, sizeof(*Diagnostics));

    status = FindBatteryPdo(&pdo, &value);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    Diagnostics->Version = MIPAD_PROTOCOL_VERSION;
    Diagnostics->Reg03 = value & 0xFFu;

    status = AcpiGetRegister(pdo, BQ25890_REG0B, &value);
    if (NT_SUCCESS(status)) {
        Diagnostics->Reg0B = value & 0xFFu;
        status = AcpiGetRegister(pdo, BQ25890_REG11, &value);
    }
    if (NT_SUCCESS(status)) {
        Diagnostics->Reg11 = value & 0xFFu;
        status = AcpiGetRegister(pdo, BQ25890_REG12, &value);
    }
    if (NT_SUCCESS(status)) {
        Diagnostics->Reg12 = value & 0xFFu;
        status = AcpiGetRegister(pdo, BQ25890_REG13, &value);
    }
    if (NT_SUCCESS(status)) {
        Diagnostics->Reg13 = value & 0xFFu;
        status = AcpiGetRegister(pdo, BQ25890_REG14, &value);
    }
    if (NT_SUCCESS(status)) {
        Diagnostics->Reg14 = value & 0xFFu;
    }

    ObDereferenceObject(pdo);
    return status;
}

static
NTSTATUS
SetChargeState(
    _In_ BOOLEAN Enable,
    _Out_ PMIPAD_CHARGE_STATE Result
)
{
    PDEVICE_OBJECT pdo = NULL;
    NTSTATUS status;
    ULONG oldReg03 = 0;
    ULONG newReg03;
    ULONG verifyReg03 = 0;

    RtlZeroMemory(Result, sizeof(*Result));

    if (!gWritesEnabled) {
        return STATUS_ACCESS_DENIED;
    }

    status = FindBatteryPdo(&pdo, &oldReg03);
    if (!NT_SUCCESS(status)) {
        return status;
    }

    /*
     * Critical safety rule: read-modify-write REG03.
     * Never replace the whole register with a hard-coded byte.
     */
    oldReg03 &= 0xFFu;

    if (Enable) {
        newReg03 = oldReg03 | BQ25890_REG03_CHG_CONFIG;
    } else {
        newReg03 = oldReg03 & ~BQ25890_REG03_CHG_CONFIG;
    }

    if (newReg03 != oldReg03) {
        status = AcpiSetRegister(pdo, BQ25890_REG03, newReg03);
        if (!NT_SUCCESS(status)) {
            ObDereferenceObject(pdo);
            return status;
        }
    }

    /*
     * Verify by reading REG03 back. Do not report success merely because
     * SETC itself returned STATUS_SUCCESS.
     */
    status = AcpiGetRegister(pdo, BQ25890_REG03, &verifyReg03);

    ObDereferenceObject(pdo);

    if (!NT_SUCCESS(status)) {
        return status;
    }

    verifyReg03 &= 0xFFu;

    Result->Version = MIPAD_PROTOCOL_VERSION;
    Result->Reg03 = verifyReg03;
    Result->ChargeEnabled =
        ((verifyReg03 & BQ25890_REG03_CHG_CONFIG) != 0) ? 1u : 0u;
    Result->WritesEnabled = 1u;
    Result->Changed = (newReg03 != oldReg03) ? 1u : 0u;

    if ((Result->ChargeEnabled != 0) != (Enable != FALSE)) {
        return STATUS_DEVICE_PROTOCOL_ERROR;
    }

    return STATUS_SUCCESS;
}

NTSTATUS
DispatchCreateClose(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
)
{
    UNREFERENCED_PARAMETER(DeviceObject);
    return CompleteIrp(Irp, STATUS_SUCCESS, 0);
}

NTSTATUS
DispatchDeviceControl(
    _In_ PDEVICE_OBJECT DeviceObject,
    _Inout_ PIRP Irp
)
{
    PIO_STACK_LOCATION stack;
    ULONG code;
    ULONG inputLength;
    ULONG outputLength;
    PVOID systemBuffer;
    NTSTATUS status;

    UNREFERENCED_PARAMETER(DeviceObject);

    stack = IoGetCurrentIrpStackLocation(Irp);
    code = stack->Parameters.DeviceIoControl.IoControlCode;
    inputLength = stack->Parameters.DeviceIoControl.InputBufferLength;
    outputLength = stack->Parameters.DeviceIoControl.OutputBufferLength;
    systemBuffer = Irp->AssociatedIrp.SystemBuffer;

    if (KeGetCurrentIrql() != PASSIVE_LEVEL) {
        return CompleteIrp(Irp, STATUS_INVALID_DEVICE_STATE, 0);
    }

    switch (code) {

    case IOCTL_MIPAD_GET_STATE:
        if (systemBuffer == NULL ||
            outputLength < sizeof(MIPAD_CHARGE_STATE)) {
            return CompleteIrp(Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }

        status = KeWaitForSingleObject(
            &gAcpiMutex,
            Executive,
            KernelMode,
            FALSE,
            NULL
        );
        if (!NT_SUCCESS(status)) {
            return CompleteIrp(Irp, status, 0);
        }
        status = ReadChargeState((PMIPAD_CHARGE_STATE)systemBuffer);
        KeReleaseMutex(&gAcpiMutex, FALSE);
        return CompleteIrp(
            Irp,
            status,
            NT_SUCCESS(status) ? sizeof(MIPAD_CHARGE_STATE) : 0
        );

    case IOCTL_MIPAD_GET_DIAGNOSTICS:
        if (systemBuffer == NULL ||
            outputLength < sizeof(MIPAD_DIAGNOSTICS)) {
            return CompleteIrp(Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }

        status = KeWaitForSingleObject(
            &gAcpiMutex,
            Executive,
            KernelMode,
            FALSE,
            NULL
        );
        if (!NT_SUCCESS(status)) {
            return CompleteIrp(Irp, status, 0);
        }
        status = ReadDiagnostics((PMIPAD_DIAGNOSTICS)systemBuffer);
        KeReleaseMutex(&gAcpiMutex, FALSE);
        return CompleteIrp(
            Irp,
            status,
            NT_SUCCESS(status) ? sizeof(MIPAD_DIAGNOSTICS) : 0
        );

    case IOCTL_MIPAD_SET_CHARGE:
        if (systemBuffer == NULL ||
            inputLength < sizeof(MIPAD_SET_REQUEST) ||
            outputLength < sizeof(MIPAD_CHARGE_STATE)) {
            return CompleteIrp(Irp, STATUS_BUFFER_TOO_SMALL, 0);
        }

        {
            ULONG enable =
                ((PMIPAD_SET_REQUEST)systemBuffer)->Enable;
            ULONG version =
                ((PMIPAD_SET_REQUEST)systemBuffer)->Version;

            if (version != MIPAD_PROTOCOL_VERSION || enable > 1u) {
                return CompleteIrp(Irp, STATUS_INVALID_PARAMETER, 0);
            }

            status = KeWaitForSingleObject(
                &gAcpiMutex,
                Executive,
                KernelMode,
                FALSE,
                NULL
            );
            if (!NT_SUCCESS(status)) {
                return CompleteIrp(Irp, status, 0);
            }
            status = SetChargeState(
                enable ? TRUE : FALSE,
                (PMIPAD_CHARGE_STATE)systemBuffer
            );
            KeReleaseMutex(&gAcpiMutex, FALSE);

            return CompleteIrp(
                Irp,
                status,
                NT_SUCCESS(status) ? sizeof(MIPAD_CHARGE_STATE) : 0
            );
        }

    default:
        return CompleteIrp(Irp, STATUS_INVALID_DEVICE_REQUEST, 0);
    }
}

static
VOID
ReadWritePolicy(
    _In_ PUNICODE_STRING RegistryPath
)
{
    WCHAR parametersBuffer[256];
    UNICODE_STRING parametersPath;
    OBJECT_ATTRIBUTES attributes;
    HANDLE key = NULL;
    UNICODE_STRING valueName;
    UCHAR valueBuffer[sizeof(KEY_VALUE_PARTIAL_INFORMATION) + sizeof(ULONG)];
    PKEY_VALUE_PARTIAL_INFORMATION value =
        (PKEY_VALUE_PARTIAL_INFORMATION)valueBuffer;
    ULONG resultLength = 0;
    NTSTATUS status;

    gWritesEnabled = FALSE;

    if (RegistryPath->Length + sizeof(L"\\Parameters") >
        sizeof(parametersBuffer)) {
        return;
    }

    RtlZeroMemory(parametersBuffer, sizeof(parametersBuffer));
    RtlZeroMemory(valueBuffer, sizeof(valueBuffer));
    RtlInitEmptyUnicodeString(
        &parametersPath,
        parametersBuffer,
        (USHORT)sizeof(parametersBuffer)
    );

    status = RtlAppendUnicodeStringToString(&parametersPath, RegistryPath);
    if (!NT_SUCCESS(status)) {
        return;
    }

    status = RtlAppendUnicodeToString(&parametersPath, L"\\Parameters");
    if (!NT_SUCCESS(status)) {
        return;
    }

    InitializeObjectAttributes(
        &attributes,
        &parametersPath,
        OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE,
        NULL,
        NULL
    );

    status = ZwOpenKey(&key, KEY_QUERY_VALUE, &attributes);
    if (!NT_SUCCESS(status)) {
        return;
    }

    RtlInitUnicodeString(&valueName, L"AllowWrites");
    status = ZwQueryValueKey(
        key,
        &valueName,
        KeyValuePartialInformation,
        valueBuffer,
        sizeof(valueBuffer),
        &resultLength
    );

    if (NT_SUCCESS(status)) {
        if (value->Type == REG_DWORD && value->DataLength == sizeof(ULONG) &&
            *(UNALIGNED ULONG *)value->Data == 1u) {
            gWritesEnabled = TRUE;
        }
    }

    ZwClose(key);
}

VOID
DriverUnload(
    _In_ PDRIVER_OBJECT DriverObject
)
{
    UNICODE_STRING dosName;

    RtlInitUnicodeString(&dosName, DOS_DEVICE_NAME);
    IoDeleteSymbolicLink(&dosName);

    if (DriverObject->DeviceObject != NULL) {
        IoDeleteDevice(DriverObject->DeviceObject);
    }
}

NTSTATUS
DriverEntry(
    _In_ PDRIVER_OBJECT DriverObject,
    _In_ PUNICODE_STRING RegistryPath
)
{
    UNICODE_STRING deviceName;
    UNICODE_STRING dosName;
    PDEVICE_OBJECT deviceObject = NULL;
    NTSTATUS status;

    DriverObject->MajorFunction[IRP_MJ_CREATE] =
        DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLEANUP] =
        DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_CLOSE] =
        DispatchCreateClose;
    DriverObject->MajorFunction[IRP_MJ_DEVICE_CONTROL] =
        DispatchDeviceControl;
    DriverObject->DriverUnload = DriverUnload;

    RtlInitUnicodeString(&deviceName, DEVICE_NAME);

    KeInitializeMutex(&gAcpiMutex, 0);
    ReadWritePolicy(RegistryPath);

    status = IoCreateDeviceSecure(
        DriverObject,
        0,
        &deviceName,
        FILE_DEVICE_UNKNOWN,
        FILE_DEVICE_SECURE_OPEN,
        FALSE,
        &SDDL_DEVOBJ_SYS_ALL_ADM_ALL,
        &GUID_DEVCLASS_MIPAD_CHARGE_CTL,
        &deviceObject
    );

    if (!NT_SUCCESS(status)) {
        return status;
    }

    deviceObject->Flags |= DO_BUFFERED_IO;

    RtlInitUnicodeString(&dosName, DOS_DEVICE_NAME);
    status = IoCreateSymbolicLink(&dosName, &deviceName);

    if (!NT_SUCCESS(status)) {
        IoDeleteDevice(deviceObject);
        return status;
    }

    deviceObject->Flags &= ~DO_DEVICE_INITIALIZING;

    return STATUS_SUCCESS;
}
