# Panduan Pengujian: Validasi Waktu Pleno

Dokumen ini berisi skenario uji, cuplikan kode, langkah eksekusi, dan expected output untuk memvalidasi waktu pleno sesuai jadwal (time window) pada sistem rekapitulasi suara berbasis Hyperledger Fabric.

Fokus pengujian ini menutup gap yang sebelumnya hanya memvalidasi:
- Tanggal tidak boleh di masa depan
- Format waktu valid

Tambahan pada dokumen ini memverifikasi secara eksplisit:
- Waktu pleno harus berada pada window yang ditentukan (tanggal dan jam)
- Input di luar window ditolak dengan alasan yang jelas

---

## 1) Konfigurasi Jadwal Pleno

Gunakan konfigurasi jadwal berikut (atau sesuaikan untuk lingkungan Anda):

- PLENO_DATE: 2024-02-14
- PLENO_START_TIME: 13:00:00
- PLENO_END_TIME: 23:59:59
- PLENO_TIMEZONE: Asia/Jakarta (WIB)

---

## 2) Modifikasi Chaincode (General)

Tambahkan konstanta konfigurasi dan fungsi validasi ke `fabric-setup/chaincode/general/general.go`:

```go
// =============================================================
// KONFIGURASI JADWAL PLENO
// =============================================================
const (
    // Tanggal pelaksanaan pleno (format: YYYY-MM-DD)
    PLENO_DATE = "2024-02-14"
    // Jam mulai pleno (format: HH:MM:SS)
    PLENO_START_TIME = "13:00:00"
    // Batas akhir input data pleno (format: HH:MM:SS)
    PLENO_END_TIME = "23:59:59"
    // Timezone (WIB = UTC+7)
    PLENO_TIMEZONE = "Asia/Jakarta"
)

// validatePlenoSchedule memvalidasi apakah waktu_pleno sesuai jadwal
func validatePlenoSchedule(inputPlenoTime string) error {
    // Load timezone
    loc, err := time.LoadLocation(PLENO_TIMEZONE)
    if err != nil {
        loc = time.FixedZone("WIB", 7*60*60)
    }
    // Parse input waktu
    var parsedInput time.Time
    var parseErr error
    formats := []string{
        "2006-01-02 15:04:05",
        "2006-01-02T15:04:05",
        time.RFC3339,
    }
    for _, format := range formats {
        parsedInput, parseErr = time.ParseInLocation(format, inputPlenoTime, loc)
        if parseErr == nil {
            break
        }
    }
    if parseErr != nil {
        return fmt.Errorf("FORMAT WAKTU SALAH: Gunakan format YYYY-MM-DD HH:MM:SS")
    }
    // Parse jadwal pleno
    plenoStart, _ := time.ParseInLocation("2006-01-02 15:04:05", PLENO_DATE+" "+PLENO_START_TIME, loc)
    plenoEnd, _ := time.ParseInLocation("2006-01-02 15:04:05", PLENO_DATE+" "+PLENO_END_TIME, loc)
    // VALIDASI 1: Tidak boleh SEBELUM jadwal pleno
    if parsedInput.Before(plenoStart) {
        return fmt.Errorf("VALIDASI WAKTU GAGAL: Waktu pleno belum dimulai. Input: %s, Jadwal: %s", inputPlenoTime, PLENO_DATE+" "+PLENO_START_TIME)
    }
    // VALIDASI 2: Tidak boleh SETELAH batas toleransi
    if parsedInput.After(plenoEnd) {
        return fmt.Errorf("VALIDASI WAKTU GAGAL: Waktu pleno sudah berakhir. Input: %s, Batas: %s", inputPlenoTime, PLENO_DATE+" "+PLENO_END_TIME)
    }
    return nil // Valid
}
```

Integrasikan ke `SubmitData` sebelum penyimpanan state:

```go
// Ekstraksi Waktu Pleno dari input
var inputPlenoTime string
if val, ok := data["waktu_pleno"]; ok {
    inputPlenoTime, _ = val.(string)
}
// VALIDASI WAKTU PLENO
if inputPlenoTime != "" {
    if err := validatePlenoSchedule(inputPlenoTime); err != nil {
        return err  // Tolak transaksi jika waktu tidak sesuai jadwal
    }
}
```

Catatan:
- Jika Anda sudah menggunakan chaincode v2 (VotingContract) dengan `SetPlenoWindow` + `ensureWindow`, Anda dapat melewati modifikasi di atas dan langsung menggunakan window submit/correct untuk pengujian. Panduan ini menyertakan contoh `SubmitData` agar independen dan mudah dieksekusi.

---

## 3) Skenario Pengujian

Delapan skenario (3 positif, 5 negatif) memastikan validasi waktu pleno sesuai spesifikasi:

| No | Skenario                         | Input waktu_pleno            | Expected |
|----|----------------------------------|------------------------------|----------|
| 1  | Positif - Tepat waktu            | 2024-02-14 13:00:00          | Diterima |
| 2  | Positif - Dalam toleransi        | 2024-02-14 18:30:00          | Diterima |
| 3  | Positif - Batas akhir            | 2024-02-14 23:59:59          | Diterima |
| 4  | Negatif - Sebelum jadwal         | 2024-02-14 10:00:00          | Ditolak  |
| 5  | Negatif - Tanggal sebelum        | 2024-02-13 13:00:00          | Ditolak  |
| 6  | Negatif - Tanggal setelah        | 2024-02-15 13:00:00          | Ditolak  |
| 7  | Negatif - Lewat toleransi        | 2024-02-15 00:00:01          | Ditolak  |
| 8  | Negatif - Format salah           | 14 Februari 2024 Jam 1 Siang | Ditolak  |

---

## 4) Kode Pengujian (Client)

Buat file `pleno_time_test.go` pada aplikasi klien (contoh: `application-go/pleno_time_test.go`). Sesuaikan koneksi Gateway (wallet, MSP, connection.json) dengan lingkungan Anda.

```go
package main

import (
    "encoding/json"
    "fmt"
    "log"
    "os"
    "time"

    gw "github.com/hyperledger/fabric-gateway/pkg/client"
)

func printResult(ok bool, label string, err error) {
    if ok {
        fmt.Printf("  Result: [✓] PASS - %s\n\n", label)
    } else {
        fmt.Printf("  Result: [x] FAIL - %s\n", label)
        if err != nil {
            fmt.Printf("  Error : %v\n\n", err)
        }
    }
}

func getTPSData() map[string]interface{} {
    return map[string]interface{}{
        "tps_id": "TPS_001",
        "operator": "KPPS_001",
        // data lain bebas, yang penting sisipkan waktu_pleno untuk uji
    }
}

func main() {
    // TODO: inisialisasi gateway sesuai environment Anda (wallet, identity, connection JSON)
    // gateway := ...
    var contract *gw.Contract // = gateway.GetNetwork("mychannel").GetContract("general")
    _ = contract

    ts := time.Now().Unix()
    fmt.Println("===============================================================")
    fmt.Println("  TEST SUITE: VALIDASI WAKTU PLENO")
    fmt.Println("  Jadwal Pleno: 2024-02-14 13:00:00 - 23:59:59")
    fmt.Println("===============================================================\n")

    // Helper to run a test case
    run := func(name, waktu string, expectOK bool, label string) {
        fmt.Println("---------------------------------------------------------------")
        fmt.Printf("  %s\n", name)
        fmt.Println("---------------------------------------------------------------")
        fmt.Printf("  Input waktu_pleno: %s\n", waktu)
        data := getTPSData()
        data["waktu_pleno"] = waktu
        payload, _ := json.Marshal(data)
        // _, err := contract.SubmitTransaction("SubmitData", fmt.Sprintf("PLENO_%d", ts), string(payload))
        var err error = nil // Hapus baris ini dan gunakan hasil SubmitTransaction di atas saat koneksi siap
        printResult((err == nil) == expectOK, label, err)
    }

    // TEST 1: POSITIF - Waktu Tepat Saat Pleno Dimulai
    run("TEST 1: POSITIF - Waktu Tepat Saat Pleno Dimulai", "2024-02-14 13:00:00", true, "Waktu tepat jadwal DITERIMA")

    // TEST 2: POSITIF - Waktu Dalam Rentang Toleransi
    run("TEST 2: POSITIF - Waktu Dalam Rentang Toleransi", "2024-02-14 18:30:00", true, "Waktu dalam toleransi DITERIMA")

    // TEST 3: POSITIF - Waktu Tepat Batas Akhir
    run("TEST 3: POSITIF - Waktu Tepat Batas Akhir", "2024-02-14 23:59:59", true, "Waktu batas akhir DITERIMA")

    // TEST 4: NEGATIF - Waktu Sebelum Jadwal Pleno
    run("TEST 4: NEGATIF - Waktu Sebelum Jadwal Pleno", "2024-02-14 10:00:00", false, "Waktu sebelum jadwal DITOLAK")

    // TEST 5: NEGATIF - Tanggal Sebelum Hari Pleno
    run("TEST 5: NEGATIF - Tanggal Sebelum Hari Pleno", "2024-02-13 13:00:00", false, "Tanggal sebelum pleno DITOLAK")

    // TEST 6: NEGATIF - Tanggal Setelah Hari Pleno
    run("TEST 6: NEGATIF - Tanggal Setelah Hari Pleno", "2024-02-15 13:00:00", false, "Tanggal setelah pleno DITOLAK")

    // TEST 7: NEGATIF - Waktu Lewat Batas Toleransi
    run("TEST 7: NEGATIF - Waktu Lewat Batas Toleransi", "2024-02-15 00:00:01", false, "Waktu lewat toleransi DITOLAK")

    // TEST 8: NEGATIF - Format Waktu Tidak Valid
    run("TEST 8: NEGATIF - Format Waktu Tidak Valid", "14 Februari 2024 Jam 1 Siang", false, "Format tidak valid DITOLAK")

    log.Println("Selesai.")
}
```

Catatan:
- Pada contoh di atas, baris pemanggilan real `SubmitTransaction` di-comment untuk menjaga dokumen ini portable. Saat menguji nyata, aktifkan koneksi gateway dan gunakan kontrak chaincode General (atau sesuai chaincode Anda).

---

## 5) Langkah Eksekusi

1. Modifikasi chaincode General (`general.go`) sesuai Bab 2.
2. Deploy ulang chaincode General:
   ```bash
   cd fabric-samples/test-network
   ./network.sh deployCC -ccn general -ccp ../path-ke/fabric-setup/chaincode/general -ccl go
   ```
3. Siapkan aplikasi klien (gateway, wallet, identity, connection profile).
4. Jalankan test client:
   ```bash
   cd application-go
   go run pleno_time_test.go
   ```
5. Simpan output terminal sebagai evidence.

---

## 6) Expected Output

```
===============================================================
  TEST SUITE: VALIDASI WAKTU PLENO
  Jadwal Pleno: 2024-02-14 13:00:00 - 23:59:59
===============================================================

---------------------------------------------------------------
  TEST 1: POSITIF - Waktu Tepat Saat Pleno Dimulai
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-14 13:00:00
  Expected: DITERIMA (tepat saat jadwal mulai)
  Result: [✓] PASS - Waktu tepat jadwal DITERIMA

---------------------------------------------------------------
  TEST 2: POSITIF - Waktu Dalam Rentang Toleransi
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-14 18:30:00
  Expected: DITERIMA (dalam rentang toleransi)
  Result: [✓] PASS - Waktu dalam toleransi DITERIMA

---------------------------------------------------------------
  TEST 3: POSITIF - Waktu Tepat Batas Akhir Toleransi
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-14 23:59:59
  Expected: DITERIMA (tepat di batas akhir)
  Result: [✓] PASS - Waktu batas akhir DITERIMA

---------------------------------------------------------------
  TEST 4: NEGATIF - Waktu Sebelum Jadwal Pleno
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-14 10:00:00
  Expected: DITOLAK (sebelum jadwal dimulai)
  Result: [✓] PASS - Waktu sebelum jadwal DITOLAK
  Error : VALIDASI WAKTU GAGAL: Waktu pleno belum dimulai.
          Input: 2024-02-14 10:00:00, Jadwal: 2024-02-14 13:00:00

---------------------------------------------------------------
  TEST 5: NEGATIF - Tanggal Sebelum Hari Pleno
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-13 13:00:00
  Expected: DITOLAK (tanggal sebelum jadwal pleno)
  Result: [✓] PASS - Tanggal sebelum pleno DITOLAK
  Error : VALIDASI WAKTU GAGAL: Waktu pleno belum dimulai.
          Input: 2024-02-13 13:00:00, Jadwal: 2024-02-14 13:00:00

---------------------------------------------------------------
  TEST 6: NEGATIF - Tanggal Setelah Hari Pleno
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-15 13:00:00
  Expected: DITOLAK (tanggal setelah jadwal pleno)
  Result: [✓] PASS - Tanggal setelah pleno DITOLAK
  Error : VALIDASI WAKTU GAGAL: Waktu pleno sudah berakhir.
          Input: 2024-02-15 13:00:00, Batas: 2024-02-14 23:59:59

---------------------------------------------------------------
  TEST 7: NEGATIF - Waktu Lewat Batas Toleransi
---------------------------------------------------------------
  Input waktu_pleno: 2024-02-15 00:00:01
  Expected: DITOLAK (sudah melewati batas toleransi)
  Result: [✓] PASS - Waktu lewat toleransi DITOLAK
  Error : VALIDASI WAKTU GAGAL: Waktu pleno sudah berakhir.
          Input: 2024-02-15 00:00:01, Batas: 2024-02-14 23:59:59

---------------------------------------------------------------
  TEST 8: NEGATIF - Format Waktu Tidak Valid
---------------------------------------------------------------
  Input waktu_pleno: 14 Februari 2024 Jam 1 Siang
  Expected: DITOLAK (format tidak valid)
  Result: [✓] PASS - Format tidak valid DITOLAK
  Error : FORMAT WAKTU SALAH: Gunakan format YYYY-MM-DD HH:MM:SS

===============================================================
  RINGKASAN HASIL PENGUJIAN
===============================================================
  Total Test Case    : 8
  Skenario Positif   : 3 (Test 1, 2, 3)
  Skenario Negatif   : 5 (Test 4, 5, 6, 7, 8)
  Status             : 8/8 PASSED (100%)
===============================================================
```

---

## 7) Catatan Penting

- Pastikan konfigurasi jadwal pleno pada chaincode dan test client sinkron.
- Ubah PLENO_DATE/START/END sesuai jadwal resmi saat deployment.
- Jika menggunakan timezone berbeda, ganti `PLENO_TIMEZONE`.
- Untuk chaincode v2 (VotingContract), Anda dapat menggunakan `SetPlenoWindow` (submit/correct) lalu memanggil fungsi submit di dalam/di luar window untuk mereplikasi skenario di atas.
