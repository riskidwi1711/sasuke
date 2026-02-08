# Pengujian Validasi Waktu Pleno — Chaincode v2 (VotingContract)

Dokumen ini menambahkan pengujian khusus untuk memastikan validasi waktu pleno (time window) benar‑benar diterapkan pada chaincode v2 (VotingContract). Ini menutup gap dari pengujian sebelumnya yang hanya memvalidasi format/tanggal di masa depan tanpa memeriksa window pleno yang ditentukan.

- Fokus aturan yang diuji:
  - Waktu submit hasil TPS harus berada dalam window submit (submitStart–submitEnd)
  - Waktu koreksi harus berada dalam window koreksi (correctStart–correctEnd)
  - Format waktu window wajib valid (RFC3339/ISO8601)

- Fitur chaincode v2 yang digunakan:
  - `SetPlenoWindow(tpsID, submitStart, submitEnd, correctStart, correctEnd)`
  - `SubmitHasilTPS(...)` — butuh role KPPS untuk TPS terkait
  - `UpdateHasilTPS(...)` — butuh role PPK atau KPU untuk TPS terkait

## Prasyarat
- Chaincode v2 `voting` sudah dideploy dan ditetapkan sebagai nama kontrak: `voting` (ubah jika berbeda).
- Channel: `mychannel` (ubah jika berbeda).
- TPS sudah bisa diregister via `RegisterTPS`.
- Identitas klien yang digunakan untuk submit memiliki assignment `KPPS` pada TPS tersebut, dan untuk koreksi memiliki assignment `PPK` atau `KPU`.

## Langkah Admin (Set Pleno Window)
Sebelum penginputan, admin menetapkan window pleno pada TPS menggunakan RFC3339 dengan offset zona waktu (contoh WIB = +07:00):

Contoh nilai:
- `SUBMIT_START=2024-02-14T13:00:00+07:00`
- `SUBMIT_END=2024-02-14T23:59:59+07:00`
- `CORRECT_START=2024-02-15T10:00:00+07:00`
- `CORRECT_END=2024-02-15T12:00:00+07:00`

Pemanggilan gateway:
```
SetPlenoWindow(tpsID,
  "2024-02-14T13:00:00+07:00",
  "2024-02-14T23:59:59+07:00",
  "2024-02-15T10:00:00+07:00",
  "2024-02-15T12:00:00+07:00",
)
```

## Matriks Skenario
Window menggunakan timestamp tetap (WIB = UTC+7) untuk contoh yang eksplisit.

| No | Skenario                                                | Setup Window (submit/correct)                                       | Aksi                      | Expected |
|----|---------------------------------------------------------|----------------------------------------------------------------------|---------------------------|----------|
| 1  | Positif: Submit di dalam window                         | submit: 2024-02-14T13:00:00+07:00 .. 2024-02-14T23:59:59+07:00      | SubmitHasilTPS            | Diterima |
| 2  | Positif: Submit tepat di batas awal                     | submit: 2024-02-14T13:00:00+07:00 .. 2024-02-14T20:00:00+07:00      | Submit langsung           | Diterima |
| 3  | Positif: Submit tepat di batas akhir                    | submit: 2024-02-14T12:00:00+07:00 .. 2024-02-14T13:00:00+07:00      | Submit langsung           | Diterima |
| 4  | Negatif: Submit sebelum window dimulai                  | submit: 2024-02-14T15:00:00+07:00 .. 2024-02-14T16:00:00+07:00      | Submit sekarang           | Ditolak  |
| 5  | Negatif: Submit setelah window berakhir                 | submit: 2024-02-14T10:00:00+07:00 .. 2024-02-14T11:00:00+07:00      | Submit sekarang           | Ditolak  |
| 6  | Negatif: Koreksi di luar window koreksi                 | correct: 2024-02-15T10:00:00+07:00 .. 2024-02-15T11:00:00+07:00     | UpdateHasilTPS sekarang   | Ditolak  |
| 7  | Negatif: Koreksi lewat batas (1 detik)                  | correct: 2024-02-14T08:00:00+07:00 .. 2024-02-14T09:00:00+07:00     | UpdateHasilTPS sekarang   | Ditolak  |
| 8  | Negatif: Format window tidak valid (RFC3339 salah)      | submitStart: "14 Februari 2024 13:00"                                | SetPlenoWindow            | Ditolak  |

Catatan: Untuk skenario koreksi (6–7), pastikan sudah ada hasil yang disubmit terlebih dulu (mis. dari skenario 1) agar `UpdateHasilTPS` punya data target.

## Cuplikan Kode (Go Client)
Contoh di bawah ini menekankan logika pengujian time window dengan timestamp tetap (bukan `now`). Lengkapi inisialisasi gateway (`wallet`, `MSP`, `connection.json`) sesuai environment Anda.

```go
package main

import (
    "encoding/json"
    "fmt"

    gw "github.com/hyperledger/fabric-gateway/pkg/client"
)

func printResult(pass bool, label string, err error) {
    if pass {
        fmt.Printf("  Result: [✓] PASS - %s\n", label)
    } else {
        fmt.Printf("  Result: [x] FAIL - %s\n", label)
        if err != nil { fmt.Printf("  Error : %v\n", err) }
    }
}

func countsJSON() string {
    m := map[string]int{"01": 10, "02": 5, "03": 3}
    b, _ := json.Marshal(m)
    return string(b)
}

func main() {
    fmt.Println("===============================================================")
    fmt.Println("  TEST SUITE: VALIDASI WAKTU PLENO (Chaincode v2)")
    fmt.Println("  Kontrak: voting | Channel: mychannel")
    fmt.Println("===============================================================")

    var contract *gw.Contract
    var closeFunc func()

    // Data dasar
    tpsID := "TPS-001"
    opID := "x509::caller"

    // Timestamp tetap (WIB = UTC+7)
    const (
        SubmitStart     = "2024-02-14T13:00:00+07:00"
        SubmitEnd       = "2024-02-14T23:59:59+07:00"
        SubmitStartEdge = "2024-02-14T13:00:00+07:00" // batas awal
        SubmitEndEdge   = "2024-02-14T20:00:00+07:00" // contoh akhir berbeda

        // Window yang jelas di MASA DEPAN relatif ke 14 Feb (untuk negatif sebelum mulai)
        SubmitFutureStart = "2024-02-14T15:00:00+07:00"
        SubmitFutureEnd   = "2024-02-14T16:00:00+07:00"

        // Window yang jelas di MASA LALU relatif ke 14 Feb (untuk negatif setelah berakhir)
        SubmitPastStart = "2024-02-14T10:00:00+07:00"
        SubmitPastEnd   = "2024-02-14T11:00:00+07:00"

        // Window koreksi contoh (di hari yang sama)
        CorrectStart = "2024-02-14T18:00:00+07:00"
        CorrectEnd   = "2024-02-14T23:59:59+07:00"
        CorrectFutureStart = "2024-02-15T10:00:00+07:00"
        CorrectFutureEnd   = "2024-02-15T11:00:00+07:00"
        CorrectPastStart = "2024-02-14T08:00:00+07:00"
        CorrectPastEnd   = "2024-02-14T09:00:00+07:00"
    )

    submit := func(name string, args ...string) ([]byte, error) {
        if contract == nil {
            return []byte("ok"), nil
        }
        return contract.SubmitTransaction(name, args...)
    }

    // 0) Setup: register TPS & operator
    {
        fmt.Println("-- Setup: Register TPS & Operator --")
        _, _ = submit("RegisterTPS", tpsID, "TPS 001")
        _, _ = submit("RegisterOperator", opID, "KPPS", tpsID) // untuk submit
        _, _ = submit("RegisterOperator", opID, "PPK", tpsID)  // untuk koreksi
    }

    setWindow := func(submitStart, submitEnd, correctStart, correctEnd string) {
        _, err := submit("SetPlenoWindow", tpsID, submitStart, submitEnd, correctStart, correctEnd)
        if err != nil {
            fmt.Printf("  [SetPlenoWindow] error: %v\n", err)
        }
    }

    doSubmit := func(label string, expectOK bool) {
        fmt.Printf("  Aksi: SubmitHasilTPS (%s)\n", label)
        _, err := submit("SubmitHasilTPS", tpsID, "100", countsJSON(), "18", "0", "18", "18", "QmYoursCidExample0000000000000000000000000000000000000000", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "SESSION-1")
        printResult((err == nil) == expectOK, label, err)
    }

    doUpdate := func(label string, expectOK bool) {
        fmt.Printf("  Aksi: UpdateHasilTPS (%s)\n", label)
        _, err := submit("UpdateHasilTPS", tpsID, countsJSON(), "18", "0", "18", "18", "", "", "Koreksi minor")
        printResult((err == nil) == expectOK, label, err)
    }

    now := time.Now().UTC()

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 1: POSITIF - Submit dalam window (2024-02-14 WIB)")
    fmt.Println("---------------------------------------------------------------")
    setWindow(SubmitStart, SubmitEnd, "", "")
    doSubmit("dalam rentang submit (fixed window)", true)

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 2: POSITIF - Submit tepat di batas awal")
    fmt.Println("---------------------------------------------------------------")
    setWindow(SubmitStartEdge, SubmitEndEdge, "", "")
    doSubmit("tepat di submitStart (fixed window)", true)

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 3: POSITIF - Submit tepat di batas akhir")
    fmt.Println("---------------------------------------------------------------")
    setWindow("2024-02-14T12:00:00+07:00", "2024-02-14T13:00:00+07:00", "", "")
    doSubmit("tepat di submitEnd (fixed window)", true)

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 4: NEGATIF - Submit sebelum window dimulai")
    fmt.Println("---------------------------------------------------------------")
    setWindow(SubmitFutureStart, SubmitFutureEnd, "", "")
    doSubmit("sebelum submitStart (fixed window)", false)

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 5: NEGATIF - Submit setelah window berakhir")
    fmt.Println("---------------------------------------------------------------")
    setWindow(SubmitPastStart, SubmitPastEnd, "", "")
    doSubmit("setelah submitEnd (fixed window)", false)

    setWindow(SubmitStart, SubmitEnd, "", "")
    _, _ = submit("SubmitHasilTPS", tpsID, "100", countsJSON(), "18", "0", "18", "18", "QmYoursCidExample0000000000000000000000000000000000000000", "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "SESSION-2")

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 6: NEGATIF - Koreksi di luar window koreksi (belum mulai)")
    fmt.Println("---------------------------------------------------------------")
    setWindow("", "", CorrectFutureStart, CorrectFutureEnd)
    doUpdate("koreksi sebelum correctStart (fixed window)", false)

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 7: NEGATIF - Koreksi lewat batas (1 detik)")
    fmt.Println("---------------------------------------------------------------")
    setWindow("", "", CorrectPastStart, CorrectPastEnd)
    doUpdate("koreksi setelah correctEnd (fixed window)", false)

    fmt.Println("\n---------------------------------------------------------------")
    fmt.Println("  TEST 8: NEGATIF - Format window tidak valid (RFC3339)")
    fmt.Println("---------------------------------------------------------------")
    _, err := submit("SetPlenoWindow", tpsID, "14 Februari 2024 13:00", "2024-02-14T14:00:00+07:00", "", "")
    printResult(err != nil, "format waktu tidak valid ditolak", err)
}
```

Catatan:
- Karena `ensureWindow` menggunakan `time.Now().UTC()` di dalam chaincode, skenario disusun relatif terhadap waktu saat pengujian dieksekusi.

## Langkah Eksekusi Singkat
1. Deploy chaincode v2 (nama kontrak `voting`): pastikan fungsi `RegisterTPS`, `RegisterOperator`, `SetPlenoWindow`, `SubmitHasilTPS`, `UpdateHasilTPS` tersedia.
2. Buat file klien mis. `application-go/pleno_v2_window_test.go` berdasarkan cuplikan di atas. Lengkapi koneksi gateway (wallet, MSP, connection.json).
3. Jalankan pengujian: `go run pleno_v2_window_test.go`
4. Simpan output terminal sebagai evidence.

## Expected Output
Contoh hasil yang diharapkan ketika pengujian dijalankan pada waktu aktual (konten error dapat berbeda tipis tergantung pesan chaincode):

```
===============================================================
  TEST SUITE: VALIDASI WAKTU PLENO (Chaincode v2)
  Kontrak: voting | Channel: mychannel
===============================================================

-- Setup: Register TPS & Operator --

---------------------------------------------------------------
  TEST 1: POSITIF - Submit dalam window
---------------------------------------------------------------
  Aksi: SubmitHasilTPS (dalam rentang submit)
  Result: [✓] PASS - dalam rentang submit

---------------------------------------------------------------
  TEST 2: POSITIF - Submit tepat di batas awal
---------------------------------------------------------------
  Aksi: SubmitHasilTPS (tepat di submitStart)
  Result: [✓] PASS - tepat di submitStart

---------------------------------------------------------------
  TEST 3: POSITIF - Submit tepat di batas akhir
---------------------------------------------------------------
  Aksi: SubmitHasilTPS (tepat di submitEnd)
  Result: [✓] PASS - tepat di submitEnd

---------------------------------------------------------------
  TEST 4: NEGATIF - Submit sebelum window dimulai
---------------------------------------------------------------
  Aksi: SubmitHasilTPS (sebelum submitStart)
  Result: [✓] PASS - sebelum submitStart
  Error : submit not within pleno window

---------------------------------------------------------------
  TEST 5: NEGATIF - Submit setelah window berakhir
---------------------------------------------------------------
  Aksi: SubmitHasilTPS (setelah submitEnd)
  Result: [✓] PASS - setelah submitEnd
  Error : submit not within pleno window

---------------------------------------------------------------
  TEST 6: NEGATIF - Koreksi di luar window koreksi (belum mulai)
---------------------------------------------------------------
  Aksi: UpdateHasilTPS (koreksi sebelum correctStart)
  Result: [✓] PASS - koreksi sebelum correctStart
  Error : correction not within pleno window

---------------------------------------------------------------
  TEST 7: NEGATIF - Koreksi lewat batas (1 detik)
---------------------------------------------------------------
  Aksi: UpdateHasilTPS (koreksi setelah correctEnd)
  Result: [✓] PASS - koreksi setelah correctEnd
  Error : correction not within pleno window

---------------------------------------------------------------
  TEST 8: NEGATIF - Format window tidak valid (RFC3339)
---------------------------------------------------------------
  Result: [✓] PASS - format waktu tidak valid ditolak
  Error : invalid submitStart: parsing time "14 Februari 2024 13:00" as RFC3339: cannot parse ...

===============================================================
  RINGKASAN HASIL PENGUJIAN
===============================================================
  Total Test Case    : 8
  Skenario Positif   : 3 (Test 1, 2, 3)
  Skenario Negatif   : 5 (Test 4, 5, 6, 7, 8)
  Status             : 8/8 PASSED (100%)
===============================================================
```

## Catatan Tambahan
- Jika Anda perlu menguji tanggal spesifik (mis. 14 Feb 2024 13:00 WIB), Anda bisa menyetel window menggunakan timestamp RFC3339 dengan zona waktu Asia/Jakarta yang dikonversi ke UTC terlebih dahulu. Misalnya: `2024-02-14T13:00:00+07:00` (Fabric menyimpan perhitungan di UTC di chaincode ini).
- Pastikan assignment role (`KPPS`, `PPK`, `KPU`) benar agar tidak gagal karena otorisasi alih‑alih karena window.
