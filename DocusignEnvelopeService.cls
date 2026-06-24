public with sharing class DocusignEnvelopeService {

    private static final Integer MAX_CHECKBOX_ANCHORS = 200;

    /**
     * Toegestane bestandstypen voor verzending via DocuSign. Centrale bron van
     * waarheid; de controllers verwijzen hierheen i.p.v. een eigen lijst te
     * onderhouden. Vergelijking gebeurt altijd lowercase.
     *
     * Deze lijst dekt de native door DocuSign ondersteunde bestandsformaten
     * (documenten, spreadsheets, presentaties, afbeeldingen). Zie
     * https://support.docusign.com/s/document-item?language=en_US&bundleId=pik1583277475390
     * voor de officiële lijst.
     *
     * List i.p.v. Set zodat de waarde rechtstreeks in een SOQL IN-binding
     * gebruikt kan worden vanuit de controllers.
     */
    public static final List<String> ALLOWED_EXTENSIONS = new List<String>{
        // Documenten / tekst
        'doc', 'docm', 'docx', 'dot', 'dotm', 'dotx',
        'pdf', 'rtf', 'txt',
        'htm', 'html',
        'msg',
        'wpd', 'wps', 'wpt',
        'xps',
        // Spreadsheets
        'csv', 'xls', 'xlsm', 'xlsx',
        // Presentaties
        'pot', 'potx', 'pps', 'ppt', 'pptm', 'pptx',
        // Afbeeldingen
        'bmp', 'gif', 'jpg', 'jpeg', 'png', 'tif', 'tiff',
        // Overige
        'xml'
    };

    public static final String ALLOWED_EXTENSIONS_LABEL =
        'Word (DOC, DOCX), Excel (XLS, XLSX, CSV), PowerPoint (PPT, PPTX), PDF, RTF, TXT, HTML, MSG, afbeeldingen (PNG, JPG, GIF, TIFF, BMP) en XPS/XML';

    /**
     * Custom exception zodat foutmeldingen in een Visualforce-context leesbaar
     * blijven. AuraHandledException levert buiten Aura/LWC vaak
     * "Script-thrown exception" op i.p.v. de echte boodschap.
     */
    public class DocusignSendException extends Exception {}

    /**
     * Publieke entry point. Bouwt de envelope met de geselecteerde bestanden
     * en verstuurt deze. De callout wordt overgeslagen tijdens tests, zodat
     * de bouwlogica gedekt kan worden zonder DocuSign aan te roepen.
     *
     * @param caseId             Case waaraan de envelope gekoppeld wordt.
     * @param contactId          Optioneel; valt terug op Case.ContactId.
     * @param contentVersionIds  De IDs van de door de gebruiker geselecteerde
     *                           en reeds gevalideerde bestanden (van de
     *                           confirm-pagina). De service zoekt NIET zelf
     *                           bestanden bij elkaar.
     */
    public static void sendFilesFromCase(Id caseId, Id contactId, List<Id> contentVersionIds) {

        dfsle.Envelope envelope = buildEnvelope(caseId, contactId, contentVersionIds);

        // Callout niet uitvoeren in testcontext; bouwlogica is wel gedekt.
        if (Test.isRunningTest()) {
            return;
        }

        dfsle.Envelope sentEnvelope = dfsle.EnvelopeService.sendEnvelope(envelope, true);
        System.debug(LoggingLevel.INFO, 'DocuSign Envelope verzonden: ' + sentEnvelope.docuSignId);
    }

    /**
     * Bouwt de volledige envelope. Geen callout. Apart gehouden voor testbaarheid.
     */
    @TestVisible
    private static dfsle.Envelope buildEnvelope(Id caseId, Id contactId, List<Id> contentVersionIds) {

        if (caseId == null) {
            throw new DocusignSendException('Case Id ontbreekt.');
        }

        // Dedupliceren met behoud van volgorde; null-entries overslaan.
        List<Id> uniqueContentVersionIds = new List<Id>();
        Set<Id> seenIds = new Set<Id>();
        if (contentVersionIds != null) {
            for (Id cvId : contentVersionIds) {
                if (cvId != null && !seenIds.contains(cvId)) {
                    seenIds.add(cvId);
                    uniqueContentVersionIds.add(cvId);
                }
            }
        }
        if (uniqueContentVersionIds.isEmpty()) {
            throw new DocusignSendException('Geen bestanden geselecteerd om te versturen.');
        }

        Case caseRecord = loadCase(caseId);

        // ----- Signer 1: controleur -----
        // Niet Case Owner gebruiken; die kan een Queue zijn. Gebruik Ter_controle_van__c.
        if (caseRecord.Ter_controle_van__c == null) {
            throw new DocusignSendException('Het veld Ter controle van is niet gevuld op deze Case.');
        }

        Id controleurId = caseRecord.Ter_controle_van__c;
        if (controleurId.getSObjectType() != User.SObjectType) {
            throw new DocusignSendException('Het veld Ter controle van verwijst niet naar een Salesforce-gebruiker.');
        }

        User controleur = loadControleur(controleurId);
        if (!controleur.IsActive) {
            throw new DocusignSendException('De controleur is geen actieve Salesforce-gebruiker.');
        }
        if (String.isBlank(controleur.Email)) {
            throw new DocusignSendException('De controleur heeft geen e-mailadres.');
        }

        // ----- Signer 2: klantcontact -----
        Id signerContactId = (contactId != null) ? contactId : caseRecord.ContactId;
        if (signerContactId == null) {
            throw new DocusignSendException('Contact Id ontbreekt en deze Case heeft geen Contact gekoppeld.');
        }

        Contact signerContact = loadContact(signerContactId);
        if (String.isBlank(signerContact.Email)) {
            throw new DocusignSendException('Het gekozen Contact heeft geen e-mailadres.');
        }

        // ----- Bestanden valideren (exact de Ids die de gebruiker bevestigde) -----
        List<ContentVersion> selectedFiles = loadFiles(uniqueContentVersionIds);

        // De verplichte handtekening-anchors (\i1\, \s2\, \n2\) staan alleen
        // in de Motrac-PDF-template. Zonder een PDF in de selectie zou dfsle
        // luid falen met een onduidelijke foutmelding; deze check geeft een
        // bruikbare melding aan elke aanroeper (UI én directe service-calls).
        Boolean selectionContainsPdf = false;
        for (ContentVersion file : selectedFiles) {
            if (file.FileExtension != null && file.FileExtension.toLowerCase() == 'pdf') {
                selectionContainsPdf = true;
                break;
            }
        }
        if (!selectionContainsPdf) {
            throw new DocusignSendException(
                'Voor de handtekening-anchors is minimaal één PDF in de selectie vereist.'
            );
        }

        // ----- E-mail teksten -----
        String caseLabel = 'Case ' + caseRecord.CaseNumber;
        Boolean multipleDocuments = selectedFiles.size() > 1;
        String documentWord = multipleDocuments ? 'documenten' : 'een document';

        String controleurSubject = 'Document ter controle in DocuSign - ' + caseLabel;
        String controleurMessage =
            'Beste ' + controleur.Name + ',\n\n' +
            'We hebben zojuist ' + documentWord + ' ter controle klaargezet in DocuSign. Gelieve deze te controleren en af te tekenen indien akkoord.\n\n' +
            'Mocht er iets niet kloppen, laat dit dan weten via salessupport@motrac.nl';

        String contactSubject = 'Officieel voorstel van Motrac - ' + caseLabel;
        String contactMessage =
            'Beste ' + signerContact.Name + ',\n\n' +
            'Hierbij delen wij ons officiële voorstel. U kunt middels onderstaande knop ' +
            (multipleDocuments ? 'de documenten' : 'het document') +
            ' controleren en indien deze aan uw wensen voldoen ondertekenen.\n\n' +
            'Mocht u nog vragen hebben over ' + (multipleDocuments ? 'deze documenten' : 'dit document') + ' dan kunt u terecht bij uw contactpersoon.\n\n' +
            'Met vriendelijke groet,\n\n' +
            'Namens ' + controleur.Name + '\n' +
            'Motrac';

        // ----- Envelope -----
        dfsle.Envelope envelope = dfsle.EnvelopeService.getEmptyEnvelope(
            new dfsle.Entity(caseRecord.Id)
        );

        // RECIPIENT 1: Controleur (tekent eerst, krijgt \i1\)
        // ignoreIfNotPresent = false -> faalt luid als de anchor ontbreekt
        // i.p.v. de verplichte handtekening stil te droppen.
        dfsle.Tab controleurInitialTab = new dfsle.InitialHereTab()
            .withScale(1.0)
            .withRequired(true)
            .withAnchor(new dfsle.Tab.Anchor(
                '\\i1\\', false, false, 'right', false, false, 'pixels', 0, 0));

        dfsle.Recipient.EmailSettings controleurEmailSettings =
            new dfsle.Recipient.EmailSettings(null, null, controleurSubject, controleurMessage);

        dfsle.Recipient controleurRecipient = dfsle.Recipient.fromSource(
                controleur.Name, controleur.Email, null, 'Controleur', new dfsle.Entity(controleur.Id))
            .withRoutingOrder(1)
            .withEmailSettings(controleurEmailSettings)
            .withTabs(new List<dfsle.Tab>{ controleurInitialTab });

        // RECIPIENT 2: Contact / klant (tekent na controleur)
        // Verplichte tabs (\s2\, \n2\) -> ignoreIfNotPresent = false
        // Anchors gelden envelope-breed: DocuSign zoekt de anchor-tekst in
        // ALLE meegestuurde documenten.
        dfsle.Tab contactSignHereTab = new dfsle.SignHereTab()
            .withScale(1.0)
            .withRequired(true)
            .withAnchor(new dfsle.Tab.Anchor(
                '\\s2\\', false, false, 'right', false, false, 'pixels', -18, -28));

        dfsle.Tab contactNameTab = new dfsle.TextTab()
            .withRequired(true)
            .withName('contact_signer_name')
            .withDataLabel('contact_signer_name')
            .withAnchor(new dfsle.Tab.Anchor(
                '\\n2\\', false, false, 'right', false, false, 'pixels', -30, -8));

        // Optioneel referentieveld -> ignoreIfNotPresent = true mag blijven
        dfsle.Tab contactReferenceTab = new dfsle.TextTab()
            .withRequired(false)
            .withName('customer_reference')
            .withDataLabel('customer_reference')
            .withAnchor(new dfsle.Tab.Anchor(
                '\\ref2\\', false, false, 'right', true, true, 'pixels', -30, -8));

        List<dfsle.Tab> contactTabs = new List<dfsle.Tab>{
            contactSignHereTab,
            contactNameTab,
            contactReferenceTab
        };
        contactTabs.addAll(buildCheckboxTabsForContact(MAX_CHECKBOX_ANCHORS));

        dfsle.Recipient.EmailSettings contactEmailSettings =
            new dfsle.Recipient.EmailSettings(null, null, contactSubject, contactMessage);

        dfsle.Recipient contactRecipient = dfsle.Recipient.fromSource(
                signerContact.Name, signerContact.Email, null, 'CustomerSigner', new dfsle.Entity(signerContact.Id))
            .withRoutingOrder(2)
            .withEmailSettings(contactEmailSettings)
            .withTabs(contactTabs);

        envelope = envelope.withRecipients(new List<dfsle.Recipient>{
            controleurRecipient, contactRecipient
        });

        // Documenten: GEEN AcroForm-transformatie. Checkboxen via expliciete anchors.
        List<dfsle.Document> docusignDocuments = dfsle.DocumentService.getDocuments(
            ContentVersion.getSObjectType(),
            new Set<Id>(uniqueContentVersionIds)
        );
        if (docusignDocuments.isEmpty()) {
            throw new DocusignSendException('DocuSign kon geen documenten laden uit de geselecteerde bestanden.');
        }
        if (docusignDocuments.size() != uniqueContentVersionIds.size()) {
            throw new DocusignSendException(
                'DocuSign kon niet alle geselecteerde bestanden laden (' +
                docusignDocuments.size() + ' van ' + uniqueContentVersionIds.size() +
                '). Open het scherm opnieuw en probeer nogmaals.'
            );
        }

        // dfsle.DocumentService.getDocuments() krijgt een Set<Id> en kan in
        // willekeurige volgorde teruggeven. DocuSign rendert documenten in de
        // array-volgorde van de envelope, dus die volgorde bepaalt wat de
        // klant ziet. Hier hersorteren we op de input-volgorde uit de UI
        // (drag-and-drop in de modal).
        Map<Id, dfsle.Document> docsBySourceId = new Map<Id, dfsle.Document>();
        for (dfsle.Document doc : docusignDocuments) {
            docsBySourceId.put(doc.sourceId, doc);
        }
        List<dfsle.Document> orderedDocs = new List<dfsle.Document>();
        for (Id cvId : uniqueContentVersionIds) {
            dfsle.Document doc = docsBySourceId.get(cvId);
            if (doc != null) {
                orderedDocs.add(doc);
            }
        }

        envelope = envelope.withDocuments(orderedDocs);
        envelope = envelope.withEmail(
            'DocuSign voorstel - ' + caseLabel,
            (multipleDocuments ? 'Deze documenten worden' : 'Dit document wordt') +
            ' via DocuSign ter controle en ondertekening aangeboden.'
        );

        return envelope;
    }

    // ------------------------------------------------------------------
    // SOQL helpers (allemaal WITH USER_MODE voor FLS/sharing-enforcement)
    // ------------------------------------------------------------------

    private static Case loadCase(Id caseId) {
        List<Case> cases = [
            SELECT Id, CaseNumber, Subject, ContactId, Ter_controle_van__c
            FROM Case
            WHERE Id = :caseId
            WITH USER_MODE
            LIMIT 1
        ];
        if (cases.isEmpty()) {
            throw new DocusignSendException('Case niet gevonden of geen toegang.');
        }
        return cases[0];
    }

    private static User loadControleur(Id controleurId) {
        List<User> users = [
            SELECT Id, Name, Email, IsActive
            FROM User
            WHERE Id = :controleurId
            WITH USER_MODE
            LIMIT 1
        ];
        if (users.isEmpty()) {
            throw new DocusignSendException('De controleur kon niet geladen worden.');
        }
        return users[0];
    }

    private static Contact loadContact(Id contactId) {
        List<Contact> contacts = [
            SELECT Id, Name, FirstName, LastName, Email
            FROM Contact
            WHERE Id = :contactId
            WITH USER_MODE
            LIMIT 1
        ];
        if (contacts.isEmpty()) {
            throw new DocusignSendException('Het gekozen Contact kon niet geladen worden.');
        }
        return contacts[0];
    }

    /**
     * Laadt en valideert de geselecteerde bestanden. Elk bestand moet nog de
     * laatste versie zijn (optimistic lock: een nieuw geüploade versie maakt
     * het oude ContentVersion-id ongeldig), een toegestaan bestandstype hebben
     * en inhoud bevatten. Retourneert de bestanden in de volgorde van de input.
     */
    private static List<ContentVersion> loadFiles(List<Id> contentVersionIds) {
        Map<Id, ContentVersion> versionsById = new Map<Id, ContentVersion>([
            SELECT Id, Title, FileExtension, ContentDocumentId, ContentSize
            FROM ContentVersion
            WHERE Id IN :contentVersionIds
            AND IsLatest = true
            WITH USER_MODE
        ]);

        Set<String> allowedExtensionsLookup = new Set<String>(ALLOWED_EXTENSIONS);

        List<ContentVersion> orderedFiles = new List<ContentVersion>();
        for (Id cvId : contentVersionIds) {
            ContentVersion file = versionsById.get(cvId);
            if (file == null) {
                throw new DocusignSendException(
                    'Eén of meer geselecteerde bestanden bestaan niet meer of zijn niet de laatste versie. Open het scherm opnieuw.'
                );
            }
            if (file.FileExtension == null || !allowedExtensionsLookup.contains(file.FileExtension.toLowerCase())) {
                throw new DocusignSendException(
                    'Bestand "' + file.Title + '" heeft geen toegestaan bestandstype. Toegestaan: ' + ALLOWED_EXTENSIONS_LABEL + '.'
                );
            }
            if (file.ContentSize == null || file.ContentSize == 0) {
                throw new DocusignSendException('Bestand "' + file.Title + '" heeft geen inhoud.');
            }
            orderedFiles.add(file);
        }
        return orderedFiles;
    }

    @TestVisible
    private static List<dfsle.Tab> buildCheckboxTabsForContact(Integer maxCheckboxes) {
        List<dfsle.Tab> checkboxTabs = new List<dfsle.Tab>();
        if (maxCheckboxes == null || maxCheckboxes <= 0) {
            return checkboxTabs;
        }

        for (Integer i = 1; i <= maxCheckboxes; i++) {
            String numberPart = String.valueOf(i).leftPad(3, '0');
            String anchor = '\\cb_' + numberPart + '\\';
            // Unieke naam + data label per checkbox, anders koppelt DocuSign ze.
            String checkboxLabel = 'motrac_cb_' + numberPart;

            // Checkboxen zijn optioneel aanwezig -> ignoreIfNotPresent = true.
            dfsle.Tab checkboxTab = new dfsle.CheckboxTab()
                .withName(checkboxLabel)
                .withDataLabel(checkboxLabel)
                .withAnchor(new dfsle.Tab.Anchor(
                    anchor, false, false, 'right', true, true, 'pixels', -9, -4));

            checkboxTabs.add(checkboxTab);
        }
        return checkboxTabs;
    }
}
