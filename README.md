# DocuSign Envelope Service — Motrac Used Afdeling

Apex-integratie waarmee een Salesforce-gebruiker vanuit een Case via een Quick Action bestanden selecteert en als DocuSign-envelope verstuurt naar een controleur (signer 1) en een klantcontact (signer 2). E-mailteksten per afdeling worden beheerd via Custom Metadata — na de eenmalige deploy is er geen Apex-aanpassing of herdeployment nodig om een nieuwe afdeling te configureren.

---

## Inhoudsopgave

1. [Hoe het werkt](#hoe-het-werkt)
2. [Projectbestanden](#projectbestanden)
3. [Vereisten](#vereisten)
4. [Let op: bestaande classes op de omgeving](#let-op-bestaande-classes-op-de-omgeving)
5. [Eenmalige deploy — Salesforce CLI](#eenmalige-deploy--salesforce-cli)
6. [Eenmalige deploy — Change Sets (zonder CLI)](#eenmalige-deploy--change-sets-zonder-cli)
7. [Quick Action koppelen aan Page Layout](#quick-action-koppelen-aan-page-layout)
8. [Nieuwe afdeling toevoegen (geen deploy nodig)](#nieuwe-afdeling-toevoegen-geen-deploy-nodig)
9. [Plaatshouders in e-mailteksten](#plaatshouders-in-e-mailteksten)
10. [Verificatie na deploy](#verificatie-na-deploy)
11. [Troubleshooting](#troubleshooting)

---

## Hoe het werkt

```
Gebruiker klikt Quick Action
        │
        ▼
Visualforce modal (DocusignCaseConfirm.page)
        │  Bestandsselectie + drag-and-drop volgorde
        ▼
DocusignCaseConfirmController.cls
        │  Valideert selectie, geeft volgorde door
        ▼
DocusignEnvelopeService.cls
        │  Laadt Case + RecordType, zoekt metadata-record,
        │  bouwt envelope met twee recipiënten
        ▼
dfsle (DocuSign for Salesforce managed package)
        │
        ▼
DocuSign — sequentieel ondertekenen:
  1. Controleur (signer 1) ontvangt e-mail → tekent af
  2. Klantcontact (signer 2) ontvangt e-mail → ondertekent
```

### E-mailteksten per afdeling

Bij het verzenden zoekt de service een `DocusignEmailTemplate__mdt`-record op met `RecordTypeDeveloperName__c` gelijk aan de `DeveloperName` van het Case-recordtype. Is er geen record gevonden, dan wordt een ingebouwde generieke fallback gebruikt — de service werkt dus altijd, ook zonder geconfigureerd metadata-record.

---

## Projectbestanden

| Bestand | Doel |
|---|---|
| `DocusignEnvelopeService.cls` | Kernlogica: envelope bouwen en verzenden |
| `DocusignEnvelopeServiceTest.cls` | Apex-testklasse (negatieve paden + happy path) |
| `DocusignCaseConfirmController.cls` | Visualforce-controller: bestandsselectie en drag-volgorde |
| `DocusignCaseQuickActionController.cls` | Aura-alternatief (optioneel, standaard ongebruikt) |
| `DocusignCaseConfirm.page` | Visualforce-pagina voor de modal |
| `objects/DocusignEmailTemplate__mdt.object-meta.xml` | Custom Metadata Type definitie |
| `objects/DocusignEmailTemplate__mdt/fields/` | Velddefinities (5 velden) |
| `customMetadata/DocusignEmailTemplate.Used.md-meta.xml` | Metadata-record voor de Used afdeling |

---

## Vereisten

Controleer de volgende punten **vóór** je begint met deployen:

- [ ] DocuSign for Salesforce managed package (`dfsle`) is geïnstalleerd in de doelorg
- [ ] Salesforce CLI v2+ (`sf`) is geïnstalleerd op de machine waarmee je deployt
      Controleer: `sf --version`
- [ ] Custom veld `Ter_controle_van__c` (User lookup) bestaat op het Case-object
- [ ] Custom object `Quote__c` bestaat met een `Name`-veld en is via een lookup-veld aan Case gekoppeld
- [ ] Case RecordType `Used` bestaat in de org (DeveloperName: `Used`)
- [ ] Je weet wat de exacte `DeveloperName` is van het Sales Nieuw RecordType
      (Vind je hier: Setup → Object Manager → Case → Record Types)

---

## Let op: bestaande classes op de omgeving

> **Belangrijk voor Motrac:** De Apex-classes (`DocusignEnvelopeService`, `DocusignCaseConfirmController`, etc.) staan al op de omgeving als onderdeel van de Sales Nieuw implementatie.
>
> Dit pakket is de **gerefactorde, metadata-gedreven versie**. Deployen overschrijft de bestaande classes — dat is de bedoeling. Na de deploy werken Sales Nieuw én Used allebei via dezelfde classes, maar met hun eigen metadata-record voor de e-mailteksten.
>
> **Actie vereist vóór deploy:** maak eerst een `DocusignEmailTemplate__mdt`-record aan voor het Sales Nieuw recordtype (zie [Nieuwe afdeling toevoegen](#nieuwe-afdeling-toevoegen-geen-deploy-nodig)). Doe je dit niet, dan vallen de Sales Nieuw-envelopes na de deploy terug op de generieke fallback-teksten in plaats van de afdelingsteksten.
>
> Volgorde aanbevolen:
> 1. Noteer de huidige e-mailteksten van Sales Nieuw (staan in de bestaande `DocusignEnvelopeService.cls` op de org)
> 2. Maak het metadata-record voor Sales Nieuw klaar (kan in sandbox)
> 3. Deploy dit pakket
> 4. Verifieer beide afdelingen

---

## Eenmalige deploy — Salesforce CLI

### Stap 1 — Repo clonen

```bash
git clone https://github.com/markkuijpers31-lab/docusign-apex-used.git
cd docusign-apex-used
```

### Stap 2 — Authenticeren bij de doelorg

```bash
sf org login web --alias motrac-prod
```

Er opent een browservenster. Log in met een account dat **Modify All Data** of een vergelijkbare deploy-permissie heeft (doorgaans een System Administrator).

Controleer daarna of de authenticatie gelukt is:

```bash
sf org display --target-org motrac-prod
```

### Stap 3 — Bestaande classes controleren (optioneel)

```bash
sf org list metadata --metadata-type ApexClass --target-org motrac-prod
```

Zoek in de uitvoer naar `DocusignEnvelopeService` en `DocusignCaseConfirmController` om te bevestigen dat deze al op de org staan.

### Stap 4 — Deployen

```bash
sf project deploy start --source-dir . --target-org motrac-prod
```

De deploy omvat:
- Alle Apex-classes en de Visualforce-pagina
- Het Custom Metadata Type (`DocusignEmailTemplate__mdt`) en alle velden
- Het metadata-record voor de Used afdeling

> **Sandbox eerst?** Vervang `motrac-prod` door je sandbox-alias. Gebruik voor een sandbox `sf org login web --alias motrac-sandbox --instance-url https://test.salesforce.com`.

### Stap 5 — Deploy verifiëren

Ga in Salesforce naar **Setup → Apex Classes** en zoek op `DocusignEnvelopeService`. De klasse moet zichtbaar zijn met een recente aanmaak-/wijzigingsdatum.

### Stap 6 — Metadata-record verifiëren

**Setup → Custom Metadata Types → Docusign Email Template → Manage Records**

Je ziet hier het record `Used`. Klik erop om de onderwerp- en bodyteksten te controleren.

---

## Eenmalige deploy — Change Sets (zonder CLI)

Als je liever Change Sets gebruikt (bijv. omdat je geen CLI-toegang hebt):

### In de **bronomgeving** (sandbox):

1. **Setup → Outbound Change Sets → New**
2. Geef de Change Set een naam, bijv. `DocuSign Used Refactor`
3. Klik **Add** → voeg de volgende componenten toe:

| Type | Naam |
|---|---|
| Apex Class | `DocusignEnvelopeService` |
| Apex Class | `DocusignEnvelopeServiceTest` |
| Apex Class | `DocusignCaseConfirmController` |
| Apex Class | `DocusignCaseQuickActionController` |
| Visualforce Page | `DocusignCaseConfirm` |
| Custom Metadata Type | `DocusignEmailTemplate__mdt` |
| Custom Metadata | `DocusignEmailTemplate.Used` |

4. Klik **Upload** en kies de doelomgeving

### In de **doelomgeving** (productie of andere sandbox):

1. **Setup → Inbound Change Sets**
2. Open de zojuist geüploade Change Set
3. Klik **Validate** en wacht tot de validatie geslaagd is
4. Klik **Deploy**

---

## Quick Action koppelen aan Page Layout

Voer deze stappen uit **per afdeling** die de Quick Action moet gebruiken.

### Stap 1 — Quick Action aanmaken

1. **Setup → Object Manager → Case → Buttons, Links, and Actions → New Action**
2. Vul in:
   - **Action Type:** Visualforce Page
   - **Visualforce Page:** `DocusignCaseConfirm`
   - **Height:** 600 px (aanbevolen)
   - **Label:** `Verstuur via DocuSign`
   - **Name:** `Verstuur_via_DocuSign` (wordt automatisch ingevuld)
3. Klik **Save**

### Stap 2 — Quick Action aan de Page Layout toevoegen

1. **Setup → Object Manager → Case → Page Layouts**
2. Open de Page Layout van de betreffende afdeling (bijv. `Used Case Layout`)
3. Sleep in de **Quick Actions** sectie de actie `Verstuur via DocuSign` naar de gewenste positie
4. Klik **Save**

Herhaal stap 2 voor elke Page Layout (elke afdeling) die de actie moet tonen.

---

## Nieuwe afdeling toevoegen (geen deploy nodig)

Na de eenmalige deploy kan een admin zelfstandig een nieuwe afdeling configureren vanuit **Setup**, zonder code-aanpassing of herdeployment.

### Stap 1 — DeveloperName van het RecordType opzoeken

1. **Setup → Object Manager → Case → Record Types**
2. Klik op het recordtype van de nieuwe afdeling
3. Noteer de waarde in het veld **Record Type Name** (de `DeveloperName`) — dit is de sleutel die de service gebruikt
   - Voorbeeld: `SalesNieuw`, `Rental`, `Service`
   - Let op hoofdletters en underscores — de waarde moet **exact** overeenkomen

### Stap 2 — Metadata-record aanmaken

1. **Setup → Custom Metadata Types → Docusign Email Template → Manage Records → New**
2. Vul in:

| Veld | Waarde |
|---|---|
| **Label** | Naam van de afdeling (bijv. `Sales Nieuw`) |
| **Custom Metadata Type Record Name** | Wordt automatisch ingevuld op basis van het label |
| **RecordTypeDeveloperName__c** | Exact de DeveloperName uit stap 1 (bijv. `SalesNieuw`) |
| **ControleurSubject__c** | Onderwerpregel voor de e-mail naar de controleur |
| **ControleurBody__c** | Bodytekst voor de e-mail naar de controleur |
| **ContactSubject__c** | Onderwerpregel voor de e-mail naar het klantcontact |
| **ContactBody__c** | Bodytekst voor de e-mail naar het klantcontact |

3. Gebruik plaatshouders in de tekstvelden (zie [Plaatshouders](#plaatshouders-in-e-mailteksten))
4. Klik **Save** — het record is direct actief, geen deploy nodig

### Stap 3 — Quick Action koppelen

Koppel de Quick Action aan de Page Layout van de nieuwe afdeling (zie [Quick Action koppelen](#quick-action-koppelen-aan-page-layout)).

---

## Plaatshouders in e-mailteksten

Gebruik deze plaatshouders in `ControleurBody__c` en `ContactBody__c`. De service vervangt ze automatisch voor elke verzending.

| Plaatshouder | Wordt vervangen door |
|---|---|
| `{quoteNumber}` | De `Name` van de gekoppelde `Quote__c` (het Q-nummer); valt terug op het CaseNumber als er geen Quote gekoppeld is |
| `{controleurName}` | De volledige naam van de gebruiker in `Ter_controle_van__c` (signer 1, de controleur) |
| `{contactName}` | De volledige naam van het Case-contact (signer 2, de klant) |
| `{documentWord}` | `"het document"` bij één bestand, `"de documenten"` bij meerdere |
| `{documentRef}` | `"dit document"` bij één bestand, `"deze documenten"` bij meerdere |

Plaatshouders werken ook in de onderwerpregels (`ControleurSubject__c` en `ContactSubject__c`), maar `{documentWord}` en `{documentRef}` zijn daar zelden zinvol.

**Voorbeeld bodytekst controleur:**

```
Beste {controleurName},

Bijgaand ontvang je ter controle het document met referentie {quoteNumber}.

Bekijk het document zorgvuldig en teken af indien alles akkoord is.

Met vriendelijke groet,
Motrac
```

---

## Verificatie na deploy

Doorloop deze checklist nadat je hebt gedeployed:

- [ ] **Apex-tests groen** — Setup → Apex Test Execution → Run All → alle tests in `DocusignEnvelopeServiceTest` slagen
      (zie [Troubleshooting](#troubleshooting) als tests falen)
- [ ] **Custom Metadata Type aanwezig** — Setup → Custom Metadata Types → `Docusign Email Template` zichtbaar
- [ ] **Metadata-record Used aanwezig** — Manage Records → record `Used` met ingevulde tekstvelden
- [ ] **Quick Action zichtbaar** — open een Case met RecordType `Used` → de actie `Verstuur via DocuSign` is zichtbaar in de actiebalk
- [ ] **Modal opent correct** — klik de actie → een modal verschijnt met de bestandslijst van de Case
- [ ] **Verzending werkt** — selecteer minimaal één PDF en eventuele andere bestanden → klik Verzenden
      - Controleur ontvangt een e-mail met het correcte onderwerp en de Q-nummer in de body
      - Na aftekening door de controleur ontvangt het klantcontact zijn e-mail
- [ ] **Sales Nieuw nog steeds werkend** — open een Case met het Sales Nieuw-recordtype en doorloop dezelfde flow

---

## Troubleshooting

### Tests falen met "Profile not found: Standard User"

De testklasse zoekt een profiel met de naam `Standard User`. In Nederlandse orgs heet dit profiel soms `Standaardgebruiker`.

**Oplossing:** zoek de juiste profielnaam op via Setup → Profiles, en pas regel 20 in `DocusignEnvelopeServiceTest.cls` aan:

```apex
Profile p = [SELECT Id FROM Profile WHERE Name = 'Standaardgebruiker' LIMIT 1];
```

### E-mails bevatten generieke fallback-teksten in plaats van afdelingsteksten

De service kon geen metadata-record vinden voor het RecordType van de Case.

**Controleer:**
1. **Setup → Custom Metadata Types → Docusign Email Template → Manage Records** — staat er een record voor deze afdeling?
2. Open het record en controleer het veld `RecordTypeDeveloperName__c`
3. Vergelijk de waarde exact (hoofdlettergevoelig) met **Setup → Object Manager → Case → Record Types → [jouw recordtype] → Record Type Name**
4. Pas de waarde in het metadata-record aan als deze niet overeenkomt en sla op

### Happy-path test faalt met een dfsle-fout

De DocuSign managed package vereist soms Custom Settings die in een lege testcontext niet aanwezig zijn.

**Wat dit betekent:** de Apex-logica (envelope bouwen, validaties, e-mailteksten) is volledig gedekt door de negatieve paden en de `loadEmailTemplate`-tests — die raken `dfsle` nooit. Als alleen de happy-path test faalt op een `dfsle`-aanroep, is de functionele code correct. Voeg de benodigde Custom Settings toe aan de testcontext als 100% coverage vereist is.

### De modal opent niet of geeft een fout

- Controleer of de Visualforce-pagina `DocusignCaseConfirm` in de org aanwezig is (Setup → Visualforce Pages)
- Controleer of de Quick Action is opgeslagen met **Action Type: Visualforce Page** en de juiste pagina geselecteerd
- Controleer of de Quick Action aan de juiste Page Layout is toegevoegd (de layout van het gebruikte Case-recordtype)

### Verzenden mislukt met "Het veld Ter controle van is niet gevuld"

Het veld `Ter_controle_van__c` op de Case is leeg. Vul het in met een actieve Salesforce-gebruiker met een e-mailadres.

### Verzenden mislukt met "minimaal één PDF"

De DocuSign-handtekening- en initiaal-anchors (`\i1\`, `\s2\`, `\n2\`) staan alleen in de Motrac PDF-template. Selecteer altijd minimaal één PDF-bestand in de modal.
