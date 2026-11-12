#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Uluslararası Sosyal Fayda Derneği (Social Business Global)
# Afet Telsizi — iPhone (Swift) ↔ TS başvurusu (= Android; Java'nın TS ile aynılığı 08.11'de masaüstü JDK ile denendi) çapraz denemesi.
# DisasterWalkieTalkiePlugin.swift'teki GERÇEK TelsizIcerik / TelsizKablo / TelsizCerceve / TelsizBirlestirici / metinTemizle kodunu
# çıkarıp derler; Swift'in ürettiği BLE çerçevelerini TS birleştirir ve çözer, TS'nin ürettiğini (sırasız) Swift birleştirir ve çözer.
# Çalıştırma (macOS, depo kökünde):  bash scripts/cross-verify/capraz-dogrula.sh
set -euo pipefail
KOK="$(cd "$(dirname "$0")/../.." && pwd)"
SW="$KOK/ios/Sources/DisasterWalkieTalkiePlugin/DisasterWalkieTalkiePlugin.swift"
GECICI="$(mktemp -d)"
trap 'rm -rf "$GECICI"' EXIT
blok() { awk -v bas="$1" 'index($0, bas) == 1 { y = 1 } y { print } y && /^}/ { exit }' "$SW"; }
{
  echo 'import Foundation'
  echo 'import CryptoKit'
  blok 'private struct TelsizIcerik: Codable {' | sed 's/^private struct/struct/'
  blok 'private struct TelsizKablo: Codable {' | sed 's/^private struct/struct/'
  blok 'enum TelsizCerceve {'
  blok 'final class TelsizBirlestirici {'
  echo 'enum TelsizMotoru {'
  echo '    static let maksMetin = 280'
  awk 'index($0, "    static func metinTemizle(") == 1 { y = 1 } y { print } y && /^    }$/ { exit }' "$SW"
  echo '}'
  cat "$KOK/scripts/cross-verify/capraz-kosucu.swift"
} > "$GECICI/main.swift"
swiftc -O -o "$GECICI/kosucu" "$GECICI/main.swift"
cd "$KOK"
npx tsx --tsconfig tsconfig.json scripts/cross-verify/capraz-dogrula.ts "$GECICI/kosucu"
