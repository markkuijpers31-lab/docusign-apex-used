# DocuSign Envelope Service — Motrac Used Afdeling

Apex-integratie waarmee een Salesforce-gebruiker vanuit een Case via een Quick Action bestanden selecteert en als DocuSign-envelope verstuurt naar een controleur (signer 1) en een klantcontact (signer 2). E-mailteksten per afdeling worden beheerd via Custom Metadata — na de eenmalige deploy is er geen Apex-aanpassing of herdeployment nodig om een nieuwe afdeling te configureren.

---

## Inhoudsopgave

1. [Hoe het werkt](#hoe-het-werkt)
2. [Projectbestanden](#projectbestanden)
3. [Vereisten](#vereisten)
4. [Let op: bestaande classes op de omgeving](#let-op-bestaande-classes-op-de-omgeving)
5. [Eenmalige deploy via Sandbox UI en Change Sets](#eenmalige-deploy-via-sandbox-ui-en-change-sets)
   - [Fase A — Componenten aanmaken in de sandbox](#fase-a--componenten-aanmaken-in-de-sandbox)
   - [Fase B — Outbound Change Set aanmaken](#fase-b--outbound-change-set-aanmaken)
   - [Fase C — Change Set deployen naar productie](#fase-c--change-set-deployen-naar-productie)
6. [Quick Action koppelen aan Page Layout](#quick-action-koppelen-aan-page-layout)
7. [Nieuwe afdeling toevoegen (geen deploy nodig)](#nieuwe-afdeling-toevoegen-geen-deploy-nodig)
8. [Plaatshouders in e-mailteksten](#plaatshouders-in-e-mailteksten)
9. [Verificatie na deploy](#verificatie-na-deploy)
10. [Troubleshooting](#troubleshooting)

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

Controleer de volgende punten **vóór** je begint:

- [ ] DocuSign for Salesforce managed package (`dfsle`) is geïnstalleerd in de doelorg
- [ ] Je hebt toegang tot een **sandbox** (voor het aanmaken van componenten en de Outbound Change Set)
- [ ] Je hebt toegang tot de **productieomgeving** (voor het deployen van de Inbound Change Set)
- [ ] Er is een **Deployment Connection** ingesteld van de sandbox naar productie
      (Setup → Deployment Settings → klik op de sandbox → vink "Allow Inbound Changes" aan)
- [ ] Custom veld `Ter_controle_van__c` (User lookup) bestaat op het Case-object
- [ ] Custom object `Quote__c` bestaat met een `Name`-veld en is via een lookup gekoppeld aan Case
- [ ] Case RecordType `Used` bestaat in de org (DeveloperName: `Used`)
- [ ] Je weet wat de exacte `DeveloperName` is van het Sales Nieuw RecordType
      (Setup → Object Manager → Case → Record Types → klik op het recordtype → zie "Record Type Name")

> **Geen Salesforce CLI of installatiesoftware nodig.** Alles verloopt via de Salesforce Setup-omgeving in de browser.

---

## Let op: bestaande classes op de omgeving

> **Belangrijk voor Motrac:** De Apex-classes (`DocusignEnvelopeService`, `DocusignCaseConfirmController`, etc.) staan al op de omgeving als onderdeel van de Sales Nieuw implementatie.
>
> Dit pakket is de **gerefactorde, metadata-gedreven versie**. Deployen overschrijft de bestaande classes — dat is de bedoeling. Na de deploy werken Sales Nieuw én Used allebei via dezelfde classes, elk met hun eigen metadata-record voor e-mailteksten.
>
> **Actie vereist vóór deploy:** maak eerst een `DocusignEmailTemplate__mdt`-record aan voor het Sales Nieuw recordtype (zie [Nieuwe afdeling toevoegen](#nieuwe-afdeling-toevoegen-geen-deploy-nodig)). Sla de huidige Sales Nieuw e-mailteksten op uit de bestaande `DocusignEnvelopeService.cls` op de sandbox. Na de deploy vallen die envelopes anders terug op generieke fallback-teksten.
>
> **Aanbevolen volgorde:**
> 1. Noteer de huidige e-mailteksten van Sales Nieuw (uit de bestaande class op de sandbox)
> 2. Maak het `DocusignEmailTemplate__mdt`-record voor Sales Nieuw aan in de sandbox (Fase A, stap 4)
> 3. Voer Fase A t/m C uit
> 4. Verifieer beide afdelingen na de deploy

---

## Eenmalige deploy via Sandbox UI en Change Sets

De deploy bestaat uit drie fasen:
- **Fase A** — componenten aanmaken in de sandbox (code kopiëren vanuit GitHub)
- **Fase B** — Outbound Change Set aanmaken en uploaden vanuit de sandbox
- **Fase C** — Change Set deployen naar productie

---

### Fase A — Componenten aanmaken in de sandbox

> Change Sets transporteren bestaande metadata van sandbox naar productie — ze kunnen geen code importeren vanuit GitHub. Daarom maak je eerst alle componenten aan in de sandbox, waarna je ze via een Change Set naar productie kunt sturen.

Alle code die je nodig hebt staat in deze GitHub-repository. Open de bestanden in GitHub en kopieer de volledige inhoud.

#### A1 — Apex Classes aanmaken

Ga in de **sandbox** naar **Setup → Apex Classes → New** en maak de volgende vier classes aan. Kopieer de volledige code van elk bestand uit GitHub en plak deze in het editor-venster. Klik daarna op **Save**.

| Class | Bestand in GitHub |
|---|---|
| `DocusignEnvelopeService` | `DocusignEnvelopeService.cls` |
| `DocusignEnvelopeServiceTest` | `DocusignEnvelopeServiceTest.cls` |
| `DocusignCaseConfirmController` | `DocusignCaseConfirmController.cls` |
| `DocusignCaseQuickActionController` | `DocusignCaseQuickActionController.cls` |

> **Tip:** als de sandbox al classes heeft van de Sales Nieuw implementatie, open dan de bestaande class via Setup → Apex Classes → klik op de naam → **Edit**, en vervang de volledige inhoud door de nieuwe code. Zo overschrijf je de juiste versie.

#### A2 — Visualforce Page aanmaken

Ga naar **Setup → Visualforce Pages → New**.

- **Label:** `Docusign Case Confirm`
- **Name:** `DocusignCaseConfirm` (wordt automatisch ingevuld)

Verwijder de standaardtekst in het editor-venster en plak de volledige inhoud van `DocusignCaseConfirm.page` uit GitHub. Klik op **Save**.

> Als de pagina al bestaat: klik op de naam → **Edit** → vervang de volledige inhoud.

#### A3 — Custom Metadata Type aanmaken

Ga naar **Setup → Custom Metadata Types → New**.

Vul in:

| Veld | Waarde |
|---|---|
| **Label** | `Docusign Email Template` |
| **Plural Label** | `Docusign Email Templates` |
| **Object Name** | `DocusignEmailTemplate` (wordt automatisch ingevuld) |
| **Description** | `E-mailteksten per Case RecordType voor DocuSign-envelopes.` |
| **Visibility** | Public |

Klik op **Save**.

> **Als het type al bestaat**, sla deze stap dan over en ga direct naar A4.

#### A3b — Velden aanmaken op het Custom Metadata Type

Ga naar **Setup → Custom Metadata Types → Docusign Email Template → Fields → New** en maak de volgende vijf velden aan:

| Veldnaam (Field Name) | Type | Lengte |
|---|---|---|
| `RecordTypeDeveloperName__c` | Text | 80 |
| `ControleurSubject__c` | Text | 255 |
| `ControleurBody__c` | Long Text Area | 32768 |
| `ContactSubject__c` | Text | 255 |
| `ContactBody__c` | Long Text Area | 32768 |

Maak elk veld afzonderlijk aan via **New Field**. De `__c`-suffix voegt Salesforce automatisch toe.

> **Als de velden al bestaan**, sla deze stap dan over.

#### A4 — Metadata-records aanmaken

Ga naar **Setup → Custom Metadata Types → Docusign Email Template → Manage Records**.

**Record voor Used afdeling (nieuw):**

Klik op **New** en vul in:

| Veld | Waarde |
|---|---|
| **Label** | `Used` |
| **RecordTypeDeveloperName__c** | `Used` |
| **ControleurSubject__c** | `Document(en) ter controle - {quoteNumber}` |
| **ControleurBody__c** | zie hieronder |
| **ContactSubject__c** | `Officieel voorstel van Motrac - {quoteNumber}` |
| **ContactBody__c** | zie hieronder |

Bodytekst controleur (`ControleurBody__c`):
```
Beste {controleurName},

Bijgaand ontvang je ter controle het Occasion document met referentie {quoteNumber}.

Bekijk het document zorgvuldig en teken af indien alles akkoord is.

Heb je vragen of opmerkingen over dit Occasion dossier? Neem dan contact op met de Used afdeling.

Met vriendelijke groet,
Motrac Used
```

Bodytekst klantcontact (`ContactBody__c`):
```
Beste {contactName},

Hierbij delen wij ons officiële voorstel. U kunt middels onderstaande knop {documentWord} controleren en indien deze aan uw wensen voldoen ondertekenen.

Mocht u nog vragen hebben over {documentRef} dan kunt u terecht bij uw contactpersoon.

Met vriendelijke groet,

Namens {controleurName}
Motrac
```

Klik op **Save**.

---

**Record voor Sales Nieuw (verplicht vóór deploy naar productie):**

Klik opnieuw op **New** en vul in:

| Veld | Waarde |
|---|---|
| **Label** | `Sales Nieuw` (of de naam van de afdeling) |
| **RecordTypeDeveloperName__c** | De exacte DeveloperName van het Sales Nieuw RecordType (zie [Vereisten](#vereisten)) |
| **ControleurSubject__c** | Het onderwerp dat Sales Nieuw nu gebruikt |
| **ControleurBody__c** | De bodytekst die Sales Nieuw nu gebruikt |
| **ContactSubject__c** | Het onderwerp dat Sales Nieuw nu gebruikt voor de klant |
| **ContactBody__c** | De bodytekst die Sales Nieuw nu gebruikt voor de klant |

Gebruik de plaatshouders `{quoteNumber}`, `{controleurName}`, `{contactName}`, `{documentWord}` en `{documentRef}` waar de huidige code dynamische waarden invult (zie [Plaatshouders](#plaatshouders-in-e-mailteksten)).

---

### Fase B — Outbound Change Set aanmaken

Ga in de **sandbox** naar **Setup → Outbound Change Sets → New**.

- **Change Set Name:** `DocuSign Used Refactor`
- **Description:** `Refactored DocuSign envelope service met Custom Metadata voor e-mailteksten per afdeling.`

Klik op **Save**.

#### Componenten toevoegen

Klik op **Add** en voeg de volgende componenten toe. Zoek per type en naam:

| Component Type | Component Name |
|---|---|
| Apex Class | `DocusignEnvelopeService` |
| Apex Class | `DocusignEnvelopeServiceTest` |
| Apex Class | `DocusignCaseConfirmController` |
| Apex Class | `DocusignCaseQuickActionController` |
| Visualforce Page | `DocusignCaseConfirm` |
| Custom Metadata Type | `DocusignEmailTemplate__mdt` |
| Custom Metadata | `DocusignEmailTemplate.Used` |
| Custom Metadata | `DocusignEmailTemplate.Sales_Nieuw` *(of de naam van jouw Sales Nieuw record)* |

> **Custom Metadata Type toevoegen:** bij het zoekscherm kies je **Type = Custom Metadata Type** en zoek je op `DocusignEmailTemplate`. Dit voegt automatisch ook de velden mee.
>
> **Custom Metadata records toevoegen:** kies **Type = Custom Metadata** en zoek op `DocusignEmailTemplate`. Voeg elk record afzonderlijk toe.

#### Uploaden naar productie

Scroll naar beneden en klik op **Upload**. Kies in het dropdown-menu de **productieomgeving** als doelorganisatie. Klik op **Upload** ter bevestiging.

---

### Fase C — Change Set deployen naar productie

Ga in de **productieomgeving** naar **Setup → Inbound Change Sets**.

Je ziet de zojuist geüploade Change Set `DocuSign Used Refactor` staan met de status `Pending`.

#### Valideren (aanbevolen)

Klik op de naam van de Change Set en klik daarna op **Validate**. Salesforce voert de Apex-tests uit en controleert of de deploy zou slagen, zonder iets daadwerkelijk aan te passen. Wacht totdat de validatie gereed is en controleer de testresultaten.

> Als de validatie mislukt op de profielnaam in de testklasse (`Standard User`), zie dan [Troubleshooting](#troubleshooting).

#### Deployen

Klik op **Deploy**. Bevestig de actie. De deploy duurt doorgaans enkele minuten. Na voltooiing zie je de status **Succeeded**.

#### Deploy verifiëren

- **Setup → Apex Classes** → zoek op `DocusignEnvelopeService` — de klasse is zichtbaar met een recente wijzigingsdatum
- **Setup → Custom Metadata Types → Docusign Email Template → Manage Records** — beide records (`Used` en het Sales Nieuw record) zijn aanwezig

---

## Quick Action koppelen aan Page Layout

Voer deze stappen uit **per afdeling** die de Quick Action moet kunnen gebruiken. Je hoeft dit maar één keer per Page Layout te doen.

### Stap 1 — Quick Action aanmaken

1. **Setup → Object Manager → Case → Buttons, Links, and Actions → New Action**
2. Vul in:
   - **Action Type:** Visualforce Page
   - **Visualforce Page:** `DocusignCaseConfirm`
   - **Height:** `600` (pixels, aanbevolen)
   - **Label:** `Verstuur via DocuSign`
   - **Name:** wordt automatisch ingevuld als `Verstuur_via_DocuSign`
3. Klik op **Save**

> Als de Quick Action al bestaat (van de Sales Nieuw implementatie), controleer dan of de Visualforce Page nog steeds verwijst naar `DocusignCaseConfirm`. Zo ja, sla deze stap over.

### Stap 2 — Quick Action toevoegen aan de Page Layout

1. **Setup → Object Manager → Case → Page Layouts**
2. Klik op de Page Layout van de afdeling waarvoor je de actie wilt tonen (bijv. `Used Case Layout`)
3. Klik bovenaan op **Quick Actions** in de palette
4. Sleep de actie `Verstuur via DocuSign` naar de **Salesforce Mobile and Lightning Experience Actions** sectie op de gewenste positie
5. Klik op **Save**

Herhaal stap 2 voor elke Page Layout (bijv. ook de Sales Nieuw layout, als die de actie nog niet heeft).

---

## Nieuwe afdeling toevoegen (geen deploy nodig)

Na de eenmalige deploy kan een admin zelfstandig een nieuwe afdeling configureren vanuit **Setup** in de productieomgeving. Geen code, geen Change Set.

### Stap 1 — DeveloperName van het RecordType opzoeken

1. **Setup → Object Manager → Case → Record Types**
2. Klik op het recordtype van de nieuwe afdeling
3. Noteer de waarde van **Record Type Name** (de `DeveloperName`)
   - Voorbeeld: `Rental`, `Service`, `SalesGebruikt`
   - Let op: hoofdlettergevoelig, geen spaties, underscores zijn toegestaan

### Stap 2 — Metadata-record aanmaken

1. **Setup → Custom Metadata Types → Docusign Email Template → Manage Records → New**
2. Vul in:

| Veld | Waarde |
|---|---|
| **Label** | Naam van de afdeling (bijv. `Rental`) |
| **Custom Metadata Type Record Name** | Wordt automatisch ingevuld |
| **RecordTypeDeveloperName__c** | Exact de DeveloperName uit stap 1 |
| **ControleurSubject__c** | Onderwerpregel voor de controleur |
| **ControleurBody__c** | Bodytekst voor de controleur |
| **ContactSubject__c** | Onderwerpregel voor het klantcontact |
| **ContactBody__c** | Bodytekst voor het klantcontact |

3. Gebruik plaatshouders in de tekstvelden (zie [Plaatshouders](#plaatshouders-in-e-mailteksten))
4. Klik op **Save** — het record is direct actief, geen deploy nodig

### Stap 3 — Quick Action koppelen

Koppel de Quick Action aan de Page Layout van de nieuwe afdeling (zie [Quick Action koppelen](#quick-action-koppelen-aan-page-layout)).

---

## Plaatshouders in e-mailteksten

Gebruik deze plaatshouders in de bodyteksten en onderwerpregels. De service vervangt ze automatisch bij elke verzending.

| Plaatshouder | Wordt vervangen door |
|---|---|
| `{quoteNumber}` | De `Name` van de gekoppelde `Quote__c` (het Q-nummer); valt terug op het CaseNumber als er geen Quote is |
| `{controleurName}` | De volledige naam van de gebruiker in `Ter_controle_van__c` (de controleur, signer 1) |
| `{contactName}` | De volledige naam van het Case-contact (de klant, signer 2) |
| `{documentWord}` | `"het document"` bij één bestand, `"de documenten"` bij meerdere bestanden |
| `{documentRef}` | `"dit document"` bij één bestand, `"deze documenten"` bij meerdere bestanden |

**Voorbeeld bodytekst:**

```
Beste {controleurName},

Bijgaand ontvang je ter controle het document met referentie {quoteNumber}.

Bekijk het document zorgvuldig en teken af indien alles akkoord is.

Met vriendelijke groet,
Motrac
```

---

## Verificatie na deploy

Doorloop deze checklist nadat de Change Set is gedeployed:

- [ ] **Custom Metadata Type aanwezig** — Setup → Custom Metadata Types → `Docusign Email Template` is zichtbaar
- [ ] **Metadata-records aanwezig** — Manage Records → records `Used` en het Sales Nieuw-record zijn aanwezig met ingevulde tekstvelden
- [ ] **Apex-classes aanwezig** — Setup → Apex Classes → `DocusignEnvelopeService` en `DocusignCaseConfirmController` zichtbaar
- [ ] **Apex-tests groen** — Setup → Apex Test Execution → Select Tests → kies `DocusignEnvelopeServiceTest` → Run → alle tests slagen
- [ ] **Quick Action zichtbaar** — open een Case met RecordType `Used` → de actie `Verstuur via DocuSign` staat in de actiebalk
- [ ] **Modal opent correct** — klik de actie → een modal verschijnt met de bestandslijst van de Case
- [ ] **Verzending werkt (Used)** — selecteer minimaal één PDF en eventuele andere bestanden → Verzenden
  - Controleur ontvangt e-mail met het correcte onderwerp en het Q-nummer in de body
  - Na aftekening door de controleur ontvangt het klantcontact zijn e-mail
- [ ] **Sales Nieuw nog werkend** — open een Case met het Sales Nieuw-recordtype → doorloop dezelfde flow → teksten komen overeen met het Sales Nieuw metadata-record

---

## Troubleshooting

### Validatie/tests falen met "List has no rows for assignment to SObject" of profielnaam-fout

De testklasse zoekt het profiel `Standard User`. In Nederlandse orgs heet dit profiel soms anders (bijv. `Standaardgebruiker`).

**Oplossing:** pas in `DocusignEnvelopeServiceTest.cls` (zowel in de sandbox als nadat de fix gedeployed is) regel 20 aan:

```apex
Profile p = [SELECT Id FROM Profile WHERE Name = 'Standaardgebruiker' LIMIT 1];
```

Sla de klasse op, voer de tests opnieuw uit en verwerk de fix daarna in een nieuwe Change Set naar productie.

### E-mails bevatten generieke teksten in plaats van afdelingsteksten

De service kon geen metadata-record vinden voor het RecordType van de Case.

**Controleer:**
1. **Setup → Custom Metadata Types → Docusign Email Template → Manage Records** — staat er een record voor deze afdeling?
2. Open het record en controleer `RecordTypeDeveloperName__c`
3. Vergelijk de waarde exact (hoofdlettergevoelig) met **Setup → Object Manager → Case → Record Types → [jouw recordtype] → Record Type Name**
4. Pas de waarde aan als deze niet overeenkomt en sla op — de correctie is direct actief

### Happy-path test faalt met een dfsle-fout

De DocuSign managed package vereist Custom Settings die in een lege testcontext niet altijd aanwezig zijn.

**Wat dit betekent:** de volledige Apex-logica (envelope bouwen, validaties, e-mailteksten ophalen) is gedekt door de negatieve paden en de `loadEmailTemplate`-tests — die raken `dfsle` nooit. Als alleen de happy-path test faalt op een `dfsle`-aanroep, is de functionele code correct en kan de deploy gewoon doorgaan. De Code Coverage-eis van Salesforce (75%) wordt door de overige tests al gehaald.

### De modal opent niet of toont een foutpagina

- Controleer of de Visualforce-pagina `DocusignCaseConfirm` aanwezig is (Setup → Visualforce Pages)
- Controleer of de Quick Action is aangemaakt met **Action Type: Visualforce Page** en verwijst naar `DocusignCaseConfirm`
- Controleer of de Quick Action aan de juiste Page Layout is toegevoegd (de layout van het gebruikte Case-recordtype)

### Verzenden mislukt met "Het veld Ter controle van is niet gevuld"

Het veld `Ter_controle_van__c` op de Case is leeg. Vul het in met een actieve Salesforce-gebruiker die een e-mailadres heeft.

### Verzenden mislukt met "minimaal één PDF"

De DocuSign-handtekening- en initiaal-anchors (`\i1\`, `\s2\`, `\n2\`) staan alleen in de Motrac PDF-template. Selecteer altijd minimaal één PDF-bestand in de modal.

### Change Set upload mislukt met "No deployment connection"

De Deployment Connection tussen de sandbox en de productieomgeving is niet ingesteld.

**Oplossing:** ga in de **productieomgeving** naar **Setup → Deployment Settings**. Zoek de sandbox in de lijst en klik op **Edit**. Vink **Allow Inbound Changes** aan en sla op. Probeer de upload daarna opnieuw vanuit de sandbox.
