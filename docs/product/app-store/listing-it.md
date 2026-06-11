# Bozza scheda App Store - italiano

Stato: testo preparato. Non inviare né pubblicare senza approvazione di Andrei.

## Campi metadati

| Campo | Bozza |
|---|---|
| Nome, max 30 caratteri | Dspeech ATC |
| Sottotitolo, max 30 caratteri | Trascrizione ATC privata |
| Testo promozionale, max 100 caratteri | Trascrizione ATC che resta su iPhone. Testo cockpit grande, offline-first, senza account. |
| URL supporto | BLOCCATO - serve un URL pubblico di supporto prima dell'invio dei metadati App Store |
| URL marketing | BLOCCATO - URL pubblico di marketing opzionale non ancora approvato |
| Keyword, max 100 byte | atc,pilot,cockpit,aviation,transcript,radio,flight,intercom,offline,airband,student |

## Descrizione, max 4000 caratteri

Dspeech trasforma l'audio live di cockpit e ATC in testo grande e leggibile a colpo d'occhio sul tuo iPhone, con la privacy come impostazione predefinita.

Il tuo audio resta sul dispositivo. Dspeech è progettato per riconoscimento vocale locale, impostazioni locali e nessun account. Nel target app attuale non ci sono SDK di analytics, SDK pubblicitari o percorsi di tracciamento.

Perché i piloti lo usano:

- Leggere le comunicazioni ATC come testo grande adatto al cockpit.
- Mantenere l'audio radio originale come riferimento autorevole usando il testo come aiuto supplementare.
- Vedere il badge LOCAL nella schermata principale.
- Vedere gli indicatori di route per input integrati e rilevati senza inviare l'audio del cockpit a un server.
- Conservare sul dispositivo le impostazioni del filtro voce pilota e lo stato del model pack.

Privacy by design:

- Nessun account richiesto.
- Nessun upload audio in modalità locale.
- Nessun upload della trascrizione in modalità locale.
- Nessun tracciamento della posizione.
- Nessun tracciamento pubblicitario.
- Nessun messaggio outbound di supporto o vendita inviato dall'app.

Avviso aeronautico importante:

Dspeech è un aiuto supplementare per il cockpit. Non è avionica certificata, non è un'autorità ATC e non sostituisce monitoraggio radio, giudizio del pilota, istruzioni ATC, procedure dell'aeromobile o dotazioni obbligatorie. L'audio originale e le autorizzazioni ufficiali restano autorevoli.

Avviso hardware:

Dspeech non promette compatibilità con ogni cuffia, intercom, aeromobile, route Bluetooth o adattatore cablato. Usa gli indicatori di route dell'app e valida la tua configurazione prima di affidarti a qualsiasi workflow.

Avviso fatturazione:

Il piano prodotto di Dspeech usa pacchetti di ore a consumo invece di un abbonamento fisso. Gli acquisti StoreKit non fanno parte di questa readiness slice e devono essere configurati solo dopo l'approvazione dell'implementazione billing.

## Note per il release manager

- Categoria primaria bozza: Navigation.
- Categoria secondaria bozza: Productivity.
- La distribuzione deve seguire solo `docs/product/pricing-top20-aviation.md`.
- Non dichiarare traduzione, affidabilità cockpit certificata o supporto hardware validato finché implementazione e prove non sono green.
- Non inviare le risposte privacy App Store tramite automazione; pubblicarle manualmente in App Store Connect dopo approvazione di Andrei.
