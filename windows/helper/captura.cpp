// captura.exe: entrega por la salida estándar todo lo que suena en el computador MENOS el audio de un proceso
// (y sus hijos). Intérprete lo usa para traducir la llamada sin volver a traducir su propia voz traducida.
//
//   captura.exe <pid a excluir>      -> float32 mono 24 kHz, sin cabecera, hasta que se cierre la salida
//   captura.exe <pid> incluir        -> al revés: solo el audio de ese proceso (para pruebas)
//
// Usa la captura por proceso de WASAPI (Windows 10 versión 2004 o posterior). Si el sistema no la tiene,
// termina con código 2 y un mensaje por la salida de error, y Intérprete usa el modo simple.
//
// Compilar: cl /nologo /EHsc /O2 /W3 captura.cpp /Fe:captura.exe ole32.lib mmdevapi.lib avrt.lib
#define NOMINMAX
#include <windows.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <avrt.h>
#include <wrl/client.h>
#include <wrl/implements.h>
#include <fcntl.h>
#include <io.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::FtmBase;

static const DWORD kRate = 24000;

// Recibe el aviso de que la interfaz de audio quedó activada.
class Handler : public RuntimeClass<RuntimeClassFlags<ClassicCom>, FtmBase, IActivateAudioInterfaceCompletionHandler> {
public:
    HANDLE done = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HRESULT result = E_FAIL;
    ComPtr<IAudioClient> client;

    STDMETHOD(ActivateCompleted)(IActivateAudioInterfaceAsyncOperation* op) override {
        HRESULT hrActivate = E_FAIL;
        ComPtr<IUnknown> unk;
        HRESULT hr = op->GetActivateResult(&hrActivate, &unk);
        if (SUCCEEDED(hr)) hr = hrActivate;
        if (SUCCEEDED(hr)) hr = unk.As(&client);
        result = hr;
        SetEvent(done);
        return S_OK;
    }
};

static int fail(const char* what, HRESULT hr, int code = 1) {
    fprintf(stderr, "%s (0x%08lx)\n", what, (unsigned long)hr);
    return code;
}

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "uso: captura.exe <pid> [incluir]\n"); return 1; }
    DWORD pid = (DWORD)strtoul(argv[1], nullptr, 10);
    bool include = argc > 2 && _stricmp(argv[2], "incluir") == 0;

    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) return fail("No pude iniciar COM", hr);

    AUDIOCLIENT_ACTIVATION_PARAMS params = {};
    params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
    params.ProcessLoopbackParams.TargetProcessId = pid;
    params.ProcessLoopbackParams.ProcessLoopbackMode =
        include ? PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE : PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE;

    PROPVARIANT pv = {};
    pv.vt = VT_BLOB;
    pv.blob.cbSize = sizeof(params);
    pv.blob.pBlobData = (BYTE*)&params;

    ComPtr<Handler> handler = Microsoft::WRL::Make<Handler>();
    ComPtr<IActivateAudioInterfaceAsyncOperation> op;
    hr = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient), &pv, handler.Get(), &op);
    if (FAILED(hr)) return fail("Este Windows no tiene captura por proceso", hr, 2);
    if (WaitForSingleObject(handler->done, 8000) != WAIT_OBJECT_0) return fail("La captura no respondio", E_FAIL, 2);
    if (FAILED(handler->result)) return fail("Este Windows no permite la captura por proceso", handler->result, 2);
    ComPtr<IAudioClient> client = handler->client;

    // Formato pedido: float32 mono a 24 kHz. Windows convierte desde el formato de la mezcla.
    WAVEFORMATEX fmt = {};
    fmt.wFormatTag = WAVE_FORMAT_IEEE_FLOAT;
    fmt.nChannels = 1;
    fmt.nSamplesPerSec = kRate;
    fmt.wBitsPerSample = 32;
    fmt.nBlockAlign = 4;
    fmt.nAvgBytesPerSec = kRate * 4;

    HANDLE ready = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                            AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK |
                                AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                            2000000 /* 200 ms */, 0, &fmt, nullptr);
    if (FAILED(hr)) return fail("No pude preparar la captura", hr, 2);
    hr = client->SetEventHandle(ready);
    if (FAILED(hr)) return fail("No pude preparar el aviso de audio", hr);
    ComPtr<IAudioCaptureClient> capture;
    hr = client->GetService(IID_PPV_ARGS(&capture));
    if (FAILED(hr)) return fail("No pude abrir la captura", hr);

    _setmode(_fileno(stdout), _O_BINARY);
    DWORD task = 0;
    HANDLE mm = AvSetMmThreadCharacteristicsW(L"Audio", &task);
    hr = client->Start();
    if (FAILED(hr)) return fail("No pude empezar la captura", hr);

    // Cuando nada suena, Windows no entrega nada. Intérprete necesita un flujo continuo (el modelo de traducción
    // cuenta el tiempo por el audio que recibe), así que el silencio se rellena aquí, al ritmo del reloj.
    LARGE_INTEGER freq, start, now;
    QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&start);
    unsigned long long written = 0;                   // muestras entregadas
    std::vector<float> zeros(kRate / 50, 0.0f);       // 20 ms
    const unsigned long long lead = kRate / 25;       // 40 ms de margen antes de rellenar
    bool ok = true;

    while (ok) {
        WaitForSingleObject(ready, 20);
        UINT32 frames = 0;
        while (ok && SUCCEEDED(capture->GetNextPacketSize(&frames)) && frames > 0) {
            BYTE* data = nullptr;
            DWORD flags = 0;
            hr = capture->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
            if (FAILED(hr)) { ok = false; break; }
            if (flags & AUDCLNT_BUFFERFLAGS_SILENT) {
                std::vector<float> z(frames, 0.0f);
                ok = fwrite(z.data(), 4, frames, stdout) == frames;
            } else {
                ok = fwrite(data, 4, frames, stdout) == frames;
            }
            written += frames;
            capture->ReleaseBuffer(frames);
        }
        QueryPerformanceCounter(&now);
        unsigned long long due = (unsigned long long)((now.QuadPart - start.QuadPart) * (double)kRate / freq.QuadPart);
        while (ok && written + lead < due) {
            ok = fwrite(zeros.data(), 4, zeros.size(), stdout) == zeros.size();
            written += zeros.size();
        }
        if (ok) ok = fflush(stdout) == 0;
    }
    client->Stop();
    if (mm) AvRevertMmThreadCharacteristics(mm);
    CoUninitialize();
    return 0;
}
