# App-Store-Eintrag Entwurf - Deutsch

Status: vorbereiteter Text. Nicht einreichen oder veröffentlichen ohne Freigabe von Andrei.

## Metadatenfelder

| Feld | Entwurf |
|---|---|
| Name, max. 30 Zeichen | Dspeech ATC |
| Untertitel, max. 30 Zeichen | Privater ATC-Text |
| Werbetext, max. 100 Zeichen | ATC-Transkript auf dem iPhone. Große Cockpit-Schrift, offline-first, ohne Konto. |
| Support-URL | BLOCKIERT - öffentliche Support-URL vor App-Store-Metadatenabgabe erforderlich |
| Marketing-URL | BLOCKIERT - optionale öffentliche Marketing-URL noch nicht freigegeben |
| Keywords, max. 100 Byte | atc,pilot,cockpit,aviation,transcript,radio,flight,intercom,offline,airband,student |

## Beschreibung, max. 4000 Zeichen

Dspeech verwandelt Live-Audio aus Cockpit und ATC-Funk in großen, gut lesbaren Text auf deinem iPhone. Datenschutz ist die Voreinstellung.

Dein Audio bleibt auf dem Gerät. Dspeech ist für lokale Spracherkennung, lokale Einstellungen und Nutzung ohne Konto konzipiert. Das aktuelle App-Ziel enthält kein Analytics-SDK, kein Werbe-SDK und keinen Tracking-Pfad.

Warum Piloten Dspeech nutzen:

- ATC-Funk als großen cockpitfreundlichen Text lesen.
- Das originale Funk-Audio bleibt maßgeblich, während Text als zusätzliche Hilfe dient.
- Den LOCAL-Hinweis auf dem Hauptbildschirm sehen.
- Eingangs-Routenindikatoren sehen, ohne Cockpit-Audio an einen Server zu senden.
- Sprachfilter-Einstellungen und Modellpaket-Status auf dem Gerät behalten.

Datenschutz durch Design:

- Kein Konto erforderlich.
- Im lokalen Modus wird kein Audio hochgeladen.
- Im lokalen Modus werden keine Transkripte hochgeladen.
- Kein Standort-Tracking.
- Kein Werbe-Tracking.
- Die App sendet keine ausgehenden Support- oder Vertriebsnachrichten.

Wichtiger Luftfahrt-Hinweis:

Dspeech ist eine zusätzliche Cockpit-Hilfe. Es ist keine zertifizierte Avionik, keine ATC-Autorität und kein Ersatz für Funküberwachung, Pilotenurteil, ATC-Anweisungen, Luftfahrzeugverfahren oder vorgeschriebene Ausrüstung. Das Original-Audio und offizielle Freigaben bleiben maßgeblich.

Hardware-Hinweis:

Dspeech verspricht keine Kompatibilität mit jedem Headset, Intercom, Flugzeug, Bluetooth-Pfad oder Kabeladapter. Nutze die Routenindikatoren der App und validiere dein Setup, bevor du dich auf einen Workflow verlässt.

Abrechnungshinweis:

Der Produktplan von Dspeech nutzt Nutzungspakete in Stunden statt eines Pauschal-Abos. StoreKit-Käufe gehören nicht zu diesem readiness-slice und dürfen erst nach Freigabe der Billing-Implementierung konfiguriert werden.

## Hinweise für Release Manager

- Primäre Kategorie: Navigation.
- Sekundäre Kategorie: Productivity.
- Länder-Verfügbarkeit muss strikt `docs/product/pricing-top20-aviation.md` folgen.
- Keine Übersetzung, zertifizierte Cockpit-Zuverlässigkeit oder validierte Hardware-Unterstützung behaupten, bis Implementierung und Nachweise bereit sind.
- Privacy Answers nicht automatisiert veröffentlichen; finale Veröffentlichung manuell in App Store Connect nach Andrei-Freigabe.
