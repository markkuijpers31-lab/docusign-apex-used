@isTest
private class DocusignEnvelopeServiceTest {

    /**
     * LET OP - org-specifieke aanpassingen die je mogelijk moet doen:
     * 1. Profielnaam: pas 'Standard User' aan naar jouw org (bv. 'Standaardgebruiker').
     * 2. Verplichte velden: vult jouw org verplichte velden op Account/Contact/Case
     *    in via validation rules of required fields? Voeg die hier toe bij de inserts.
     * 3. Ter_controle_van__c moet een User-lookup zijn op Case.
     *
     * De callout naar DocuSign wordt in de service overgeslagen via
     * Test.isRunningTest(). buildEnvelope() roept wel dfsle-bouwmethodes aan
     * (getEmptyEnvelope, getDocuments). Als jouw DFSLE-package custom settings
     * vereist die in een lege testcontext ontbreken, kan de happy-path test
     * falen op die dfsle-call. De negatieve paden raken dfsle nooit en zijn
     * dus altijd betrouwbaar.
     */

    private static User makeControleur(Boolean active, Boolean withEmail) {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String unique = String.valueOf(Datetime.now().getTime()) + String.valueOf(Math.round(Math.random() * 100000));
        User u = new User(
            ProfileId = p.Id,
            LastName = 'Controleur',
            Alias = 'ctrl',
            Email = withEmail ? 'controleur_' + unique + '@example.com' : null,
            Username = 'controleur_' + unique + '@example.com.dsleTest',
            CommunityNickname = 'ctrl' + unique.right(6),
            TimeZoneSidKey = 'Europe/Amsterdam',
            LocaleSidKey = 'nl_NL',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'nl_NL',
            IsActive = active
        );
        // runAs voorkomt MIXED_DML met de niet-setup objecten (Account/Contact/Case)
        // die in dezelfde testtransactie worden aangemaakt.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert u;
        }
        return u;
    }

    private static Id makeCase(Id contactId, Id accountId, Id controleurId) {
        Case c = new Case(
            Subject = 'DocuSign test',
            AccountId = accountId,
            ContactId = contactId,
            Ter_controle_van__c = controleurId
        );
        insert c;
        return c.Id;
    }

    private static Id attachFile(Id caseId, String pathOnClient) {
        ContentVersion cv = new ContentVersion(
            Title = pathOnClient.substringBeforeLast('.'),
            PathOnClient = pathOnClient,            // 'test.pdf' -> FileExtension 'pdf'
            VersionData = Blob.valueOf('FILE-CONTENT-NOT-EMPTY'),
            IsMajorVersion = true
        );
        insert cv;

        Id cdId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;
        insert new ContentDocumentLink(
            ContentDocumentId = cdId,
            LinkedEntityId = caseId,
            ShareType = 'V'
        );
        return [SELECT Id FROM ContentVersion WHERE ContentDocumentId = :cdId AND IsLatest = true].Id;
    }

    // ---------------------------------------------------------------
    // Negatieve paden - raken dfsle NIET, altijd betrouwbaar
    // ---------------------------------------------------------------

    @isTest
    static void buildEnvelope_nullCase_throws() {
        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(null, null, null);
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht DocusignSendException bij null caseId.');
    }

    @isTest
    static void buildEnvelope_geenBestanden_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, new List<Id>());
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Geen bestanden'), 'Verwacht melding over lege selectie.');
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij lege bestandsselectie.');
    }

    @isTest
    static void buildEnvelope_geenControleur_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;

        Id caseId = makeCase(ct.Id, a.Id, null); // geen controleur
        Id cvId = attachFile(caseId, 'test.pdf');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, new List<Id>{ cvId });
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
            System.assert(e.getMessage().contains('Ter controle van'), 'Verwacht melding over controleur.');
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij ontbrekende controleur.');
    }

    @isTest
    static void buildEnvelope_inactieveControleur_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(false, true); // inactief

        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id cvId = attachFile(caseId, 'test.pdf');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, new List<Id>{ cvId });
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij inactieve controleur.');
    }

    @isTest
    static void buildEnvelope_nietBestaandBestand_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        // geen bestand gekoppeld; geef een nep-Id mee dat niet bestaat
        Id fakeCvId = ContentVersion.SObjectType.getDescribe().getKeyPrefix() + '000000000000AAA';

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, new List<Id>{ fakeCvId });
        } catch (Exception e) {
            thrown = true; // DocusignSendException of QueryException
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij niet-bestaand bestand.');
    }

    @isTest
    static void buildEnvelope_verkeerdeExtensie_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id cvId = attachFile(caseId, 'test.exe'); // niet toegestaan type

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, new List<Id>{ cvId });
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
            System.assert(e.getMessage().contains('bestandstype'), 'Verwacht melding over bestandstype.');
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception bij niet-toegestane extensie.');
    }

    @isTest
    static void buildEnvelope_geenPdfInSelectie_throws() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id docxId = attachFile(caseId, 'specificatie.docx');
        Id xlsxId = attachFile(caseId, 'prijslijst.xlsx');

        Boolean thrown = false;
        Test.startTest();
        try {
            DocusignEnvelopeService.buildEnvelope(caseId, ct.Id, new List<Id>{ docxId, xlsxId });
        } catch (DocusignEnvelopeService.DocusignSendException e) {
            thrown = true;
            System.assert(e.getMessage().contains('PDF'), 'Verwacht melding over verplichte PDF.');
        }
        Test.stopTest();
        System.assert(thrown, 'Verwacht exception zonder PDF in selectie.');
    }

    @isTest
    static void checkboxTabs_buildsExpectedCount() {
        Test.startTest();
        List<dfsle.Tab> tabs10 = DocusignEnvelopeService.buildCheckboxTabsForContact(10);
        List<dfsle.Tab> tabs0  = DocusignEnvelopeService.buildCheckboxTabsForContact(0);
        Test.stopTest();
        System.assertEquals(10, tabs10.size(), 'Verwacht 10 checkbox-tabs.');
        System.assertEquals(0,  tabs0.size(),  'Verwacht 0 tabs bij 0.');
    }

    // ---------------------------------------------------------------
    // Controller-pad - valideert errors + selectie (geen dfsle)
    // ---------------------------------------------------------------

    @isTest
    static void controller_geenBestanden_zetError() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id); // geen bestanden

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        Test.stopTest();

        System.assert(ctrl.getHasErrors(), 'Verwacht errors zonder bestanden.');
        System.assert(ctrl.getDisableSend(), 'Knop moet disabled zijn.');
        System.assertEquals(0, ctrl.getFileCount(), 'Verwacht lege bestandslijst.');
    }

    @isTest
    static void controller_meerdereBestanden_geladen() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');
        attachFile(caseId, 'specificatie.docx');
        attachFile(caseId, 'prijslijst.xlsx');
        attachFile(caseId, 'oude_prijslijst.xls'); // legacy Excel-formaat, óók toegestaan
        attachFile(caseId, 'presentatie.pptx');
        attachFile(caseId, 'logo.png');
        attachFile(caseId, 'leesmij.txt');
        attachFile(caseId, 'malware.exe'); // mag NIET in de lijst verschijnen

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        Test.stopTest();

        System.assert(!ctrl.getHasErrors(), 'Verwacht geen errors: ' + String.join(ctrl.errors, '; '));
        System.assertEquals(7, ctrl.getFileCount(), 'Verwacht 7 toegestane bestanden (exe uitgefilterd).');
        for (DocusignCaseConfirmController.FileOption option : ctrl.files) {
            System.assertEquals(false, option.selected, 'Bestanden mogen niet voorgeselecteerd zijn.');
        }
        System.assert(!ctrl.getDisableSend(), 'Knop moet enabled zijn.');
    }

    @isTest
    static void controller_sendZonderSelectie_zetError() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        ctrl.sendEnvelope(); // niets aangevinkt
        Test.stopTest();

        System.assertEquals(false, ctrl.sent, 'Zonder selectie mag er niet verzonden worden.');
        Boolean selectieMeldingGevonden = false;
        for (ApexPages.Message msg : ApexPages.getMessages()) {
            if (msg.getDetail().contains('minimaal één bestand')) {
                selectieMeldingGevonden = true;
            }
        }
        System.assert(selectieMeldingGevonden, 'Verwacht foutmelding over lege selectie.');
    }

    @isTest
    static void controller_sendZonderPdfInSelectie_zetError() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'specificatie.docx');
        attachFile(caseId, 'prijslijst.xlsx');

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        // Selecteer alle bestanden — geen PDF tussen.
        for (DocusignCaseConfirmController.FileOption option : ctrl.files) {
            option.selected = true;
        }
        ctrl.sendEnvelope();
        Test.stopTest();

        System.assertEquals(false, ctrl.sent, 'Zonder PDF in selectie mag er niet verzonden worden.');
        Boolean pdfMeldingGevonden = false;
        for (ApexPages.Message msg : ApexPages.getMessages()) {
            if (msg.getDetail().contains('minimaal één PDF')) {
                pdfMeldingGevonden = true;
            }
        }
        System.assert(pdfMeldingGevonden, 'Verwacht foutmelding over verplichte PDF.');
    }

    // ---------------------------------------------------------------
    // Happy paths - raken dfsle. Zie LET OP bovenaan als dit faalt.
    // ---------------------------------------------------------------

    @isTest
    static void sendFilesFromCase_meerdereBestanden_happyPath() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id pdfId  = attachFile(caseId, 'voorstel.pdf');
        Id docxId = attachFile(caseId, 'specificatie.docx');
        Id txtId  = attachFile(caseId, 'notities.txt');

        Test.startTest();
        // Via de publieke entry point; callout wordt geskipt door Test.isRunningTest().
        DocusignEnvelopeService.sendFilesFromCase(caseId, ct.Id, new List<Id>{ pdfId, docxId, txtId });
        Test.stopTest();
        // Geen exception = pad doorlopen. Assertions op de envelope kun je toevoegen
        // door buildEnvelope() direct aan te roepen en recipients/documents te inspecteren.
    }

    @isTest
    static void applyDragOrder_herschiktSelectieVolgensUiVolgorde() {
        // 15-char Salesforce Ids; geen 18-char checksum-validatie nodig.
        String prefix = ContentVersion.SObjectType.getDescribe().getKeyPrefix();
        Id a = prefix + '000000000001';
        Id b = prefix + '000000000002';
        Id c = prefix + '000000000003';
        Id d = prefix + '000000000004';

        Test.startTest();
        // Standaard: alle vier geselecteerd in volgorde a,b,c,d.
        // UI sleept naar c,a,d,b (b expliciet als laatste).
        List<Id> reordered = DocusignCaseConfirmController.applyDragOrder(
            new List<Id>{ a, b, c, d },
            c + ';' + a + ';' + d + ';' + b
        );

        // Lege orderedIds -> originele volgorde
        List<Id> untouched = DocusignCaseConfirmController.applyDragOrder(
            new List<Id>{ a, b, c }, ''
        );

        // orderedIds bevat alleen een deel van de selectie -> rest achteraan
        List<Id> partial = DocusignCaseConfirmController.applyDragOrder(
            new List<Id>{ a, b, c, d },
            c + ';' + a   // b en d ontbreken; behouden originele volgorde
        );

        // orderedIds bevat ongeldige tokens en niet-geselecteerde Ids -> negeren
        List<Id> noisy = DocusignCaseConfirmController.applyDragOrder(
            new List<Id>{ a, b },
            'not-an-id;' + d + ';' + b + ';;' + a
        );
        Test.stopTest();

        System.assertEquals(new List<Id>{ c, a, d, b }, reordered, 'Drag-volgorde moet exact overgenomen worden.');
        System.assertEquals(new List<Id>{ a, b, c }, untouched, 'Lege orderedIds: originele volgorde.');
        System.assertEquals(new List<Id>{ c, a, b, d }, partial, 'Ontbrekende items horen achteraan in originele volgorde.');
        System.assertEquals(new List<Id>{ b, a }, noisy, 'Ruis en niet-geselecteerde Ids moeten genegeerd worden.');
    }

    @isTest
    static void controller_dragOrder_wordtDoorgegevenAanService() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        Id pdfId  = attachFile(caseId, 'voorstel.pdf');
        Id docxId = attachFile(caseId, 'specificatie.docx');
        Id xlsxId = attachFile(caseId, 'prijslijst.xlsx');

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        for (DocusignCaseConfirmController.FileOption option : ctrl.files) {
            option.selected = true;
        }
        // Sales support sleept docx eerst, dan pdf, dan xlsx.
        ctrl.orderedIds = docxId + ';' + pdfId + ';' + xlsxId;
        ctrl.sendEnvelope();
        Test.stopTest();

        System.assertEquals(true, ctrl.sent, 'Verwacht succesvolle verzending.');
        System.assertEquals(3, ctrl.lastSelectionSent.size(), 'Verwacht drie items in de service-aanroep.');
        System.assertEquals(docxId, ctrl.lastSelectionSent[0], 'Eerste positie = eerst gesleept.');
        System.assertEquals(pdfId,  ctrl.lastSelectionSent[1], 'Tweede positie = als tweede gesleept.');
        System.assertEquals(xlsxId, ctrl.lastSelectionSent[2], 'Derde positie = als derde gesleept.');
    }

    @isTest
    static void controller_sendMetSelectie_happyPath() {
        Account a = new Account(Name = 'Acme');
        insert a;
        Contact ct = new Contact(LastName = 'Klant', Email = 'klant@example.com', AccountId = a.Id);
        insert ct;
        User u = makeControleur(true, true);
        Id caseId = makeCase(ct.Id, a.Id, u.Id);
        attachFile(caseId, 'voorstel.pdf');
        attachFile(caseId, 'specificatie.docx');

        Test.startTest();
        ApexPages.StandardController sc = new ApexPages.StandardController(new Case(Id = caseId));
        DocusignCaseConfirmController ctrl = new DocusignCaseConfirmController(sc);
        // Selecteer beide bestanden, zoals de gebruiker via de checkboxen doet.
        for (DocusignCaseConfirmController.FileOption option : ctrl.files) {
            option.selected = true;
        }
        ctrl.sendEnvelope();
        Test.stopTest();

        System.assertEquals(true, ctrl.sent, 'Verwacht succesvolle verzending met geselecteerde bestanden.');
    }
}
