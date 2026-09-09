/**
 * Tests for LeadQAController.
 *
 * Lead_Question__mdt records cannot be inserted in a test, so the question
 * selector exposes a `mockConfigs` seam. Configuring it in-memory keeps these
 * tests deterministic and independent of whatever metadata a given sandbox
 * happens to contain -- the same reason SeeAllData is never used.
 */
@IsTest(SeeAllData=false)
private class LeadQAControllerTest {

    // Matter Type / Sub Type are almost certainly restricted picklists, and their
    // values differ per org. Hard-coding literals here would make the whole class
    // fail to insert data in any org that spells them differently -- the same
    // portability trap as hard-coding a Profile name. Values are read from the
    // describe instead, with literals only as a fallback for a plain text field.
    private static final String TYPE_A;
    private static final String TYPE_B;
    private static final String SUB_A;
    private static final String SUB_B;
    private static final Boolean NA_SUB_TYPE_ALLOWED;

    static {
        List<String> types = allowedValues(
            Lead.Matter_Type__c,
            new List<String>{ 'Family Law', 'Personal Injury' }
        );
        List<String> subTypes = allowedValues(
            Lead.Matter_Sub_Type__c,
            new List<String>{ 'Divorce', 'Adoption' }
        );
        TYPE_A = types[0];
        TYPE_B = types.size() > 1 ? types[1] : types[0];
        SUB_A = subTypes[0];
        SUB_B = subTypes.size() > 1 ? subTypes[1] : subTypes[0];
        NA_SUB_TYPE_ALLOWED = isAllowed(Lead.Matter_Sub_Type__c, 'N/A');
    }

    /** Active picklist values, or the supplied fallbacks for a non-picklist field. */
    private static List<String> allowedValues(
        Schema.SObjectField field,
        List<String> fallback
    ) {
        List<Schema.PicklistEntry> entries = field.getDescribe().getPicklistEntries();
        if (entries.isEmpty()) {
            return fallback;
        }
        List<String> values = new List<String>();
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive() && entry.getValue() != 'N/A') {
                values.add(entry.getValue());
            }
        }
        return values.isEmpty() ? fallback : values;
    }

    private static Boolean isAllowed(Schema.SObjectField field, String value) {
        List<Schema.PicklistEntry> entries = field.getDescribe().getPicklistEntries();
        if (entries.isEmpty()) {
            return true; // free text field
        }
        for (Schema.PicklistEntry entry : entries) {
            if (entry.isActive() && entry.getValue() == value) {
                return true;
            }
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Fixtures
    // ------------------------------------------------------------------

    private static Lead newLead(String matterType, String subType) {
        Lead record = new Lead(
            LastName = 'Tester',
            Company = 'Acme Legal',
            Matter_Type__c = matterType,
            Matter_Sub_Type__c = subType
        );
        insert record;
        return record;
    }

    /** A metadata record carrying `count` sequentially numbered questions. */
    private static Lead_Question__mdt config(String matterType, String subType, Integer count) {
        Lead_Question__mdt cfg = new Lead_Question__mdt(
            Matter_Type__c = matterType,
            Sub_Type__c = subType
        );
        for (Integer i = 1; i <= count; i++) {
            cfg.put('Question_' + i + '__c', matterType + ' question ' + i);
        }
        return cfg;
    }

    private static List<LeadQAController.QuestionAnswer> answerAll(
        LeadQAController.LeadQAContext context,
        String answerPrefix
    ) {
        List<LeadQAController.QuestionAnswer> rows =
            new List<LeadQAController.QuestionAnswer>();
        for (LeadQAController.QuestionAnswer row : context.questions) {
            rows.add(new LeadQAController.QuestionAnswer(
                row.slot,
                row.question,
                answerPrefix + row.slot
            ));
        }
        return rows;
    }

    // ------------------------------------------------------------------
    // getLeadQA
    // ------------------------------------------------------------------

    @IsTest
    static void getLeadQA_leadWithStoredQuestions_returnsOnlyPopulatedSlots() {
        Lead record = newLead(TYPE_B, null);
        record.Question_1__c = 'Where did it happen?';
        record.Answer_1__c = 'Bristol';
        record.Question_2__c = 'When did it happen?';
        update record;

        Test.startTest();
        LeadQAController.LeadQAContext context = LeadQAController.getLeadQA(record.Id);
        Test.stopTest();

        Assert.areEqual(2, context.questions.size(), 'Only populated slots should be returned');
        Assert.areEqual('Where did it happen?', context.questions[0].question, 'Wrong question 1');
        Assert.areEqual('Bristol', context.questions[0].answer, 'Wrong answer 1');
        Assert.isNull(context.questions[1].answer, 'Question 2 was never answered');
        Assert.isTrue(context.hasMatterType, 'Matter Type is set on this Lead');
    }

    @IsTest
    static void getLeadQA_leadWithoutMatterType_returnsEmptyContextNotAnError() {
        // The original controller threw "List has no rows for assignment" here,
        // which is the exact state the UI is designed to prompt the user about.
        Lead record = newLead(null, null);

        Test.startTest();
        LeadQAController.LeadQAContext context = LeadQAController.getLeadQA(record.Id);
        Test.stopTest();

        Assert.isNotNull(context, 'A Lead with no Matter Type must still load');
        Assert.isFalse(context.hasMatterType, 'hasMatterType should be false');
        Assert.areEqual(0, context.questions.size(), 'No questions expected');
    }

    @IsTest
    static void getLeadQA_nonLeadId_throwsAuraHandledException() {
        Account other = new Account(Name = 'Not a Lead');
        insert other;

        Test.startTest();
        try {
            LeadQAController.getLeadQA(other.Id);
            Assert.fail('Expected an AuraHandledException for a non-Lead Id');
        } catch (AuraHandledException e) {
            Assert.areEqual(
                'A valid Lead record Id is required.',
                e.getMessage(),
                'Wrong error message'
            );
        }
        Test.stopTest();
    }

    // ------------------------------------------------------------------
    // getMatterQuestions
    // ------------------------------------------------------------------

    @IsTest
    static void getMatterQuestions_configuredType_returnsConfiguredQuestions() {
        Lead record = newLead(TYPE_B, null);
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_B, null, 4) };

        Test.startTest();
        LeadQAController.LeadQAContext context =
            LeadQAController.getMatterQuestions(record.Id);
        Test.stopTest();

        Assert.areEqual(4, context.questions.size(), 'Four questions are configured');
        Assert.areEqual(1, context.questions[0].slot, 'Slots start at 1');
        Assert.areEqual(4, context.questions[3].slot, 'Slots run consecutively');
        Assert.areEqual(
            TYPE_B + ' question 4',
            context.questions[3].question,
            'Wrong question text'
        );
    }

    @IsTest
    static void getMatterQuestions_subTypeConfigured_prefersSubTypeOverType() {
        Lead record = newLead(TYPE_A, SUB_A);
        LeadQuestionSelector.mockConfigs = new List<Lead_Question__mdt>{
            config(TYPE_A, null, 2),
            config(TYPE_A, SUB_A, 5)
        };

        Test.startTest();
        LeadQAController.LeadQAContext context =
            LeadQAController.getMatterQuestions(record.Id);
        Test.stopTest();

        Assert.areEqual(5, context.questions.size(), 'The Sub Type record should win');
    }

    @IsTest
    static void getMatterQuestions_subTypeNotConfigured_fallsBackToMatterType() {
        Lead record = newLead(TYPE_A, SUB_B);
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_A, null, 3) };

        Test.startTest();
        LeadQAController.LeadQAContext context =
            LeadQAController.getMatterQuestions(record.Id);
        Test.stopTest();

        Assert.areEqual(3, context.questions.size(), 'Should fall back to the type level set');
    }

    @IsTest
    static void getMatterQuestions_naSubType_usesMatterTypeRecord() {
        if (!NA_SUB_TYPE_ALLOWED) {
            return; // This org's Sub Type picklist has no "N/A" value to test with.
        }
        Lead record = newLead(TYPE_A, 'N/A');
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_A, null, 2) };

        Test.startTest();
        LeadQAController.LeadQAContext context =
            LeadQAController.getMatterQuestions(record.Id);
        Test.stopTest();

        Assert.areEqual(2, context.questions.size(), 'N/A means "no sub type"');
    }

    @IsTest
    static void getMatterQuestions_answerReused_onlyWhereQuestionTextIsUnchanged() {
        Lead record = newLead(TYPE_A, null);
        record.Question_1__c = TYPE_A + ' question 1';
        record.Answer_1__c = 'Keep me';
        record.Question_2__c = 'A question no longer asked';
        record.Answer_2__c = 'Drop me';
        update record;

        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_A, null, 2) };

        Test.startTest();
        LeadQAController.LeadQAContext context =
            LeadQAController.getMatterQuestions(record.Id);
        Test.stopTest();

        Assert.areEqual(2, context.questions.size(), 'Two questions configured');
        Assert.areEqual(
            'Keep me',
            context.questions[0].answer,
            'The answer to an unchanged question should survive'
        );
        Assert.isNull(
            context.questions[1].answer,
            'The answer to a retired question must not be carried onto a new one'
        );
    }

    @IsTest
    static void getMatterQuestions_noMatterType_throwsActionableError() {
        Lead record = newLead(null, null);

        Test.startTest();
        try {
            LeadQAController.getMatterQuestions(record.Id);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('Set a Matter Type'),
                'The message should tell the user what to do, got: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void getMatterQuestions_noConfigForType_throwsActionableError() {
        Lead record = newLead(TYPE_A, null);
        LeadQuestionSelector.mockConfigs = new List<Lead_Question__mdt>();

        Test.startTest();
        try {
            LeadQAController.getMatterQuestions(record.Id);
            Assert.fail('Expected an AuraHandledException');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('No question set is configured'),
                'Unexpected message: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    // ------------------------------------------------------------------
    // saveAnswers -- the behaviour the rewrite exists for
    // ------------------------------------------------------------------

    @IsTest
    static void saveAnswers_writesQuestionsAndAnswers() {
        Lead record = newLead(TYPE_B, null);
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_B, null, 3) };
        LeadQAController.LeadQAContext draft =
            LeadQAController.getMatterQuestions(record.Id);

        Test.startTest();
        LeadQAController.LeadQAContext saved =
            LeadQAController.saveAnswers(record.Id, answerAll(draft, 'Answer '));
        Test.stopTest();

        Lead reloaded = [
            SELECT Question_1__c, Answer_1__c, Question_3__c, Answer_3__c
            FROM Lead WHERE Id = :record.Id
        ];
        Assert.areEqual(
            TYPE_B + ' question 1', reloaded.Question_1__c, 'Question 1 not written'
        );
        Assert.areEqual('Answer 1', reloaded.Answer_1__c, 'Answer 1 not written');
        Assert.areEqual('Answer 3', reloaded.Answer_3__c, 'Answer 3 not written');
        Assert.areEqual(3, saved.questions.size(), 'Saved context should reflect the record');
    }

    @IsTest
    static void saveAnswers_shorterQuestionSet_clearsEveryTrailingSlot() {
        // The reported defect: switch a Lead from a 10 question matter type to a
        // 4 question one and the six leftover questions and answers must be gone.
        Lead record = newLead(TYPE_A, null);
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_A, null, 10) };
        LeadQAController.saveAnswers(
            record.Id,
            answerAll(LeadQAController.getMatterQuestions(record.Id), 'Old ')
        );

        record.Matter_Type__c = TYPE_B;
        update record;
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_B, null, 4) };

        Test.startTest();
        LeadQAController.LeadQAContext saved = LeadQAController.saveAnswers(
            record.Id,
            answerAll(LeadQAController.getMatterQuestions(record.Id), 'New ')
        );
        Test.stopTest();

        Lead reloaded = [
            SELECT Question_4__c, Answer_4__c, Question_5__c, Answer_5__c,
                   Question_10__c, Answer_10__c
            FROM Lead WHERE Id = :record.Id
        ];
        Assert.areEqual('New 4', reloaded.Answer_4__c, 'The new set should be written');
        Assert.isNull(reloaded.Question_5__c, 'Slot 5 question must be cleared');
        Assert.isNull(reloaded.Answer_5__c, 'Slot 5 answer must be cleared');
        Assert.isNull(reloaded.Question_10__c, 'Slot 10 question must be cleared');
        Assert.isNull(reloaded.Answer_10__c, 'Slot 10 answer must be cleared');
        Assert.areEqual(4, saved.questions.size(), 'Only the new questions remain');
    }

    @IsTest
    static void saveAnswers_blankAnswer_storesQuestionWithNullAnswer() {
        Lead record = newLead(TYPE_B, null);
        LeadQuestionSelector.mockConfigs =
            new List<Lead_Question__mdt>{ config(TYPE_B, null, 2) };
        LeadQAController.LeadQAContext draft =
            LeadQAController.getMatterQuestions(record.Id);

        List<LeadQAController.QuestionAnswer> rows =
            new List<LeadQAController.QuestionAnswer>{
                new LeadQAController.QuestionAnswer(1, draft.questions[0].question, 'Given'),
                new LeadQAController.QuestionAnswer(2, draft.questions[1].question, '   ')
            };

        Test.startTest();
        LeadQAController.saveAnswers(record.Id, rows);
        Test.stopTest();

        Lead reloaded = [
            SELECT Question_2__c, Answer_2__c FROM Lead WHERE Id = :record.Id
        ];
        Assert.areEqual(
            TYPE_B + ' question 2',
            reloaded.Question_2__c,
            'An unanswered question is still recorded'
        );
        Assert.isNull(reloaded.Answer_2__c, 'A whitespace answer is stored as null');
    }

    @IsTest
    static void saveAnswers_emptyList_clearsTheWholeQuestionnaire() {
        Lead record = newLead(TYPE_B, null);
        record.Question_1__c = 'Old question';
        record.Answer_1__c = 'Old answer';
        update record;

        Test.startTest();
        LeadQAController.LeadQAContext saved = LeadQAController.saveAnswers(
            record.Id,
            new List<LeadQAController.QuestionAnswer>()
        );
        Test.stopTest();

        Lead reloaded = [SELECT Question_1__c, Answer_1__c FROM Lead WHERE Id = :record.Id];
        Assert.isNull(reloaded.Question_1__c, 'Question 1 should be cleared');
        Assert.isNull(reloaded.Answer_1__c, 'Answer 1 should be cleared');
        Assert.areEqual(0, saved.questions.size(), 'Nothing left to show');
    }

    @IsTest
    static void saveAnswers_nullPayload_clearsWithoutThrowing() {
        Lead record = newLead(TYPE_B, null);
        record.Question_1__c = 'Old question';
        update record;

        Test.startTest();
        LeadQAController.LeadQAContext saved =
            LeadQAController.saveAnswers(record.Id, null);
        Test.stopTest();

        Assert.areEqual(0, saved.questions.size(), 'A null payload clears the questionnaire');
    }

    @IsTest
    static void saveAnswers_slotOutOfRange_isRejected() {
        Lead record = newLead(TYPE_B, null);

        Test.startTest();
        try {
            LeadQAController.saveAnswers(
                record.Id,
                new List<LeadQAController.QuestionAnswer>{
                    new LeadQAController.QuestionAnswer(99, 'Injected question', 'x')
                }
            );
            Assert.fail('Expected slot 99 to be rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('not valid'),
                'Unexpected message: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void saveAnswers_duplicateSlot_isRejected() {
        Lead record = newLead(TYPE_B, null);

        Test.startTest();
        try {
            LeadQAController.saveAnswers(
                record.Id,
                new List<LeadQAController.QuestionAnswer>{
                    new LeadQAController.QuestionAnswer(1, 'First', 'a'),
                    new LeadQAController.QuestionAnswer(1, 'Second', 'b')
                }
            );
            Assert.fail('Expected a duplicate slot to be rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('more than once'),
                'Unexpected message: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    @IsTest
    static void saveAnswers_answerLongerThanTheField_isRejectedNotTruncated() {
        Lead record = newLead(TYPE_B, null);
        Integer limitLength = Lead.Answer_1__c.getDescribe().getLength();

        Test.startTest();
        try {
            LeadQAController.saveAnswers(
                record.Id,
                new List<LeadQAController.QuestionAnswer>{
                    new LeadQAController.QuestionAnswer(
                        1, 'A question', 'x'.repeat(limitLength + 1)
                    )
                }
            );
            Assert.fail('Expected an over-length answer to be rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('The maximum is'),
                'Unexpected message: ' + e.getMessage()
            );
        }
        Test.stopTest();

        Lead reloaded = [SELECT Answer_1__c FROM Lead WHERE Id = :record.Id];
        Assert.isNull(reloaded.Answer_1__c, 'Nothing should have been written');
    }

    @IsTest
    static void saveAnswers_moreRowsThanSlots_isRejected() {
        Lead record = newLead(TYPE_B, null);
        List<LeadQAController.QuestionAnswer> rows =
            new List<LeadQAController.QuestionAnswer>();
        for (Integer i = 1; i <= LeadQASchema.MAX_SLOTS + 1; i++) {
            rows.add(new LeadQAController.QuestionAnswer(i, 'Question ' + i, 'a'));
        }

        Test.startTest();
        try {
            LeadQAController.saveAnswers(record.Id, rows);
            Assert.fail('Expected an oversized payload to be rejected');
        } catch (AuraHandledException e) {
            Assert.isTrue(
                e.getMessage().contains('at most'),
                'Unexpected message: ' + e.getMessage()
            );
        }
        Test.stopTest();
    }

    // ------------------------------------------------------------------
    // Bulk and permissions
    // ------------------------------------------------------------------

    @IsTest
    static void saveAnswers_fullQuestionSet_costsTheSameAsOneQuestion() {
        // The bulkification property that matters for this method: its query and
        // DML cost is fixed, not proportional to the number of questions. A 15
        // question save must cost exactly what a 1 question save costs.
        Lead record = newLead(TYPE_B, null);
        LeadQuestionSelector.mockConfigs = new List<Lead_Question__mdt>{
            config(TYPE_B, null, LeadQASchema.MAX_SLOTS)
        };
        LeadQAController.LeadQAContext draft =
            LeadQAController.getMatterQuestions(record.Id);

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        Integer dmlBefore = Limits.getDmlStatements();
        LeadQAController.saveAnswers(record.Id, answerAll(draft, 'Answer '));
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Integer dmlUsed = Limits.getDmlStatements() - dmlBefore;
        Test.stopTest();

        // One read to authorise, one write, one read back for the response.
        Assert.areEqual(2, queriesUsed, 'Saving 15 questions should cost 2 queries');
        Assert.areEqual(1, dmlUsed, 'Saving 15 questions should cost 1 DML statement');
        Assert.areEqual(
            LeadQASchema.MAX_SLOTS,
            [SELECT COUNT() FROM Lead WHERE Id = :record.Id AND Answer_15__c != NULL],
            'Every slot should have been written'
        );
    }

    @IsTest
    static void saveAnswers_repeatedCalls_haveConstantCostPerCall() {
        // This is a single record UI endpoint: it is called once per page save,
        // not with a collection. What is asserted here is that the per call cost
        // stays flat, so the endpoint has a predictable ceiling. Anything needing
        // to save many Leads at once should get its own list based method rather
        // than calling this one in a loop.
        List<Lead> leads = new List<Lead>();
        for (Integer i = 0; i < 40; i++) {
            leads.add(new Lead(
                LastName = 'Bulk ' + i,
                Company = 'Acme Legal',
                Matter_Type__c = TYPE_B
            ));
        }
        insert leads;

        List<LeadQAController.QuestionAnswer> rows =
            new List<LeadQAController.QuestionAnswer>{
                new LeadQAController.QuestionAnswer(1, 'Bulk question', 'Bulk answer')
            };

        Test.startTest();
        Integer queriesBefore = Limits.getQueries();
        for (Lead record : leads) {
            LeadQAController.saveAnswers(record.Id, rows);
        }
        Integer queriesUsed = Limits.getQueries() - queriesBefore;
        Test.stopTest();

        Assert.areEqual(80, queriesUsed, '40 saves at a fixed 2 queries each');
        Assert.areEqual(
            40,
            [SELECT COUNT() FROM Lead WHERE Answer_1__c = 'Bulk answer'],
            'Every Lead should have been saved'
        );
    }

    @IsTest
    static void saveAnswers_userWithoutLeadAccess_isDenied() {
        Lead record = newLead(TYPE_B, null);
        User restricted = buildMinimumAccessUser();
        if (restricted == null) {
            return; // Profile unavailable in this org; see buildMinimumAccessUser.
        }

        Test.startTest();
        System.runAs(restricted) {
            try {
                LeadQAController.saveAnswers(
                    record.Id,
                    new List<LeadQAController.QuestionAnswer>{
                        new LeadQAController.QuestionAnswer(1, 'Q', 'A')
                    }
                );
                Assert.fail('A user with no Lead access must not be able to save');
            } catch (Exception e) {
                Assert.isTrue(
                    e instanceof AuraHandledException,
                    'Expected an AuraHandledException, got ' + e.getTypeName()
                );
            }
        }
        Test.stopTest();

        Lead reloaded = [SELECT Answer_1__c FROM Lead WHERE Id = :record.Id];
        Assert.isNull(reloaded.Answer_1__c, 'Nothing should have been written');
    }

    /**
     * Builds a user on a profile with no Lead access. Profiles are queried rather
     * than hard-coded, and a missing profile skips the test rather than failing a
     * deployment in an org that does not have it.
     */
    private static User buildMinimumAccessUser() {
        List<Profile> profiles = [
            SELECT Id FROM Profile
            WHERE Name IN ('Minimum Access - Salesforce', 'Chatter Free User')
            ORDER BY Name LIMIT 1
        ];
        if (profiles.isEmpty()) {
            return null;
        }
        User restricted = new User(
            ProfileId = profiles[0].Id,
            LastName = 'Restricted',
            Email = 'restricted.leadqa@example.invalid',
            Username = 'restricted.leadqa.' + DateTime.now().getTime() + '@example.invalid',
            Alias = 'rleadqa',
            TimeZoneSidKey = 'Europe/London',
            LocaleSidKey = 'en_GB',
            EmailEncodingKey = 'UTF-8',
            LanguageLocaleKey = 'en_US'
        );
        // User is a setup object. Inserting it in the same transaction as the Lead
        // DML above would throw MIXED_DML_OPERATION; runAs isolates it.
        System.runAs(new User(Id = UserInfo.getUserId())) {
            insert restricted;
        }
        return restricted;
    }
}
