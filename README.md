# PalmAnnotate Swift

PalmAnnotate untuk iPhone dengan SwiftUI, iOS 17 atau lebih baru. Perangkat acuan adalah iPhone 11. Aplikasi menyediakan Multisisi 4/8 foto, Multisisi Video dengan audio, dan Berat Tandan 1/2 foto. Dua modul foto mendukung deteksi ONNX, penyuntingan kotak, dan penautan tandan. Sesi dan draf disimpan lokal. Sampel yang selesai dapat dibagikan sebagai ZIP. Layar Hasil menyediakan CSV, Identity JSON, dan log anotasi untuk sampel beranotasi.

## Jalankan di simulator

Gunakan Xcode dengan runtime simulator iPhone dan [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
./Scripts/prepare-detector.sh
xcodegen generate
open PalmAnnotate.xcodeproj
```

Skrip mengambil ONNX Runtime 1.20.1 dari paket resmi Microsoft di NuGet dan model dari revisi Android yang dipatok. Skrip memeriksa SHA-256 setiap unduhan.

Di Xcode, pilih skema **PalmAnnotate** dan simulator iPhone 11. Gunakan **Run** untuk membuka aplikasi dan **Test** untuk menjalankan tes UI dalam posisi tegak dan mendatar. Simulator menyediakan pemilih foto dan MP4 untuk mencoba alur pengumpulan dengan berkas contoh. Gunakan iPhone 11 fisik untuk memeriksa kamera, mikrofon, GPS, dan alur berbagi.

Jalankan tes penyimpanan, ekspor, dan deteksi dengan `swift test --package-path Packages/PalmCore`. Atur `PALM_LEGACY_CORPUS` ke folder `ground_truth/annotations` dari Baseline-SawitMVC untuk menjalankan pemeriksaan korpus lokal.

[Rancangan dan kontrak ekspor](DESIGN.md) · [Status porting dan panduan agen](AGENTS.md)

## Distribusi App Store

Tautan **Kebijakan Privasi** pada layar utama membuka [kebijakan yang disertakan dalam aplikasi](App/PRIVACY.md). Gunakan URL publik untuk kebijakan yang sama di App Store Connect setelah dokumen tersedia di repositori publik. Periksa juga setelan App Privacy berdasarkan alur distribusi dan penanganan ekspor oleh pengelola aplikasi.

Gunakan [daftar pemeriksaan App Store](docs/APP-STORE.md) untuk menyiapkan arsip, metadata, screenshot, dan bahan App Review.

### Dukungan

Laporkan masalah atau beri masukan melalui [GitHub Issues PalmAnnotate](https://github.com/ULM-SawitMVC/PalmAnnotate-Swift/issues). Sertakan versi aplikasi dari layar utama, model iPhone, versi iOS, modul, dan langkah untuk mengulangi masalah. Gunakan data contoh untuk screenshot atau berkas ekspor agar foto lapangan, nama operator, dan koordinat asli tetap privat.

## Atribusi

This software is based in part on the work of the Independent JPEG Group.
