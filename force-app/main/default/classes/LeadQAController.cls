/**
 * Controller for the `leadQuestionAnswer` Lightning Web Component.
 *
 * The matter-intake questionnaire lives in 15 paired `Question_N__c` /
 * `Answer_N__c` fields on Lead. Which questions apply to a Lead is configured
 * declaratively in `Lead_Question__mdt`, keyed by Matter Type and an optional
 * Matter Sub Type.
 *
 * Sharing: `with sharing`. Every entry point is invoked from a Lead record page
 * on behalf of the user looking at it, so record visibility must be that user's.
 * Record sharing is only one of four security layers, so CRUD and FLS are
 * enforced separately and explicitly via `USER_MODE` on every query and DML.
 *
 * @see LeadQAControllerTest
 */
public with sharing class LeadQAController {

    /** Number of Question/Answer slots the Lead schema provides. */
    @TestVisible
    private static final Integer MAX_SLOTS = 15;

    /** Sub Type value that means "this matter type has no sub types". */
    private static final String NA_SUB_TYPE = 'N/A';

    /** Slot number -> `Question_N__c` API name, for slots that exist in this org. */
    private static final Map<Integer, String> QUESTION_FIELD_BY_SLOT;

    /** Slot number -> `Answer_N__c` API name, for slots that exist in this org. */
    private static final Map<Integer, String> ANSWER_FIELD_BY_SLOT;

    /** Slot numbers present in this org, ascending. */
    private static final List<Integer> SLOTS;

    /** Shortest `Answer_N__c` length, so the UI can cap input before DML fails. */
    private static final Integer ANSWER_MAX_LENGTH;

    /** Shortest `Question_N__c` length. */
    private static final Integer QUESTION_MAX_LENGTH;

    /** True when the running user may update every Answer field. */
    private static final Boolean ANSWERS_UPDATEABLE;

    /** Dynamic SELECT over the slot fields; see `fetchLead` for why it is safe. */
    private static final String LEAD_QUERY;

    /** Test seam: when set, `Lead_Question__mdt` is resolved from here, not SOQL. */
    @TestVisible
    private static List<Lead_Question__mdt> mockQuestionConfigs;

    static {
        // Field API names are derived from a compile-time pattern, but the org may
        // not have all 15 slots deployed. Resolving them against the describe means
        // a missing field degrades gracefully instead of throwing an opaque
        // "No such column" at runtime.
        // Hoisted: `getMap()` is a describe call and must not be re-issued per
        // iteration. The copy is lower-cased because `getMap()` does not promise
        // the casing of its keys and `Map<String, ...>` lookups are case sensitive.
        Map<String, Schema.SObjectField> leadFields = Schema.SObjectType.Lead.fields.getMap();
        Map<String, Schema.SObjectField> fieldsByLowerName =
            new Map<String, Schema.SObjectField>();
        for (String name : leadFields.keySet()) {
            fieldsByLowerName.put(name.toLowerCase(), leadFields.get(name));
        }

        QUESTION_FIELD_BY_SLOT = new Map<Integer, String>();
        ANSWER_FIELD_BY_SLOT = new Map<Integer, String>();
        SLOTS = new List<Integer>();

        Integer answerLength = null;
        Integer questionLength = null;
        Boolean answersUpdateable = true;

        for (Integer slot = 1; slot <= MAX_SLOTS; slot++) {
            String questionName = 'Question_' + slot + '__c';
            String answerName = 'Answer_' + slot + '__c';

            Schema.SObjectField questionField = fieldsByLowerName.get(questionName.toLowerCase());
            Schema.SObjectField answerField = fieldsByLowerName.get(answerName.toLowerCase());
            if (questionField == null || answerField == null) {
                continue;
            }

            // 15 field describes in a static initialiser: once per transaction, not
            // per record. Field describes are cheap; `getGlobalDescribe()` is not,
            // and is deliberately avoided.
            Schema.DescribeFieldResult questionInfo = questionField.getDescribe();
            Schema.DescribeFieldResult answerInfo = answerField.getDescribe();

            questionLength = min(questionLength, questionInfo.getLength());
            answerLength = min(answerLength, answerInfo.getLength());
            answersUpdateable = answersUpdateable && answerInfo.isUpdateable();

            SLOTS.add(slot);
            QUESTION_FIELD_BY_SLOT.put(slot, questionInfo.getName());
            ANSWER_FIELD_BY_SLOT.put(slot, answerInfo.getName());
        }

        QUESTION_MAX_LENGTH = questionLength == null ? 255 : questionLength;
        ANSWER_MAX_LENGTH = answerLength == null ? 255 : answerLength;
        ANSWERS_UPDATEABLE = answersUpdateable
            && !SLOTS.isEmpty()
            && Schema.SObjectType.Lead.isUpdateable();

        List<String> selectFields = new List<String>{
            'Id', 'Name', 'Matter_Type__c', 'Matter_Sub_Type__c'
        };
        selectFields.addAll(QUESTION_FIELD_BY_SLOT.values());
        selectFields.addAll(ANSWER_FIELD_BY_SLOT.values());
        LEAD_QUERY =
            'SELECT ' + String.join(selectFields, ', ') +
            ' FROM Lead WHERE Id = :leadId LIMIT 1';
    }

    // ---------------------------------------------------------------------
    // Entry points
    // ---------------------------------------------------------------------

    /**
     * Returns the questionnaire as it is currently stored on the Lead.
     *
     * Cacheable so the component can `@wire` it and refresh it with
     * `refreshApex` after a save. Returns an empty question list rather than
     * throwing when the Lead has no Matter Type yet -- that is a normal state
     * the UI renders a prompt for, not an error.
     */
    @AuraEnabled(cacheable=true)
    public static LeadQAContext getLeadQA(Id recordId) {
        try {
            Lead record = fetchLead(recordId);
            return buildContext(record, storedQuestions(record));
        } catch (Exception e) {
            throw userFacing(e, 'Unable to load the questions for this Lead.');
        }
    }

    /**
     * Rebuilds the questionnaire from `Lead_Question__mdt` for the Lead's current
     * Matter Type / Sub Type, discarding any slot the new configuration does not
     * define.
     *
     * Answers survive only where the exact same question text is still asked --
     * matched on text rather than on slot number, so an answer follows its
     * question if the configuration reorders it. Every other answer is dropped,
     * because an answer to a question that is no longer being asked is stale data.
     *
     * Nothing is written here. The result is a draft the user reviews and then
     * persists with `saveAnswers`.
     */
    @AuraEnabled
    public static LeadQAContext getMatterQuestions(Id recordId) {
        try {
            Lead record = fetchLead(recordId);

            if (String.isBlank(record.Matter_Type__c)) {
                throw new QuestionnaireException(
                    'Set a Matter Type on this Lead before loading matter specific questions.'
                );
            }

            Lead_Question__mdt config = findQuestionConfig(
                record.Matter_Type__c,
                record.Matter_Sub_Type__c
            );
            if (config == null) {
                throw new QuestionnaireException(
                    'No question set is configured for Matter Type "' +
                    record.Matter_Type__c + '"' +
                    (isRealSubType(record.Matter_Sub_Type__c)
                        ? ' / Sub Type "' + record.Matter_Sub_Type__c + '"'
                        : '') +
                    '. Ask an administrator to add a Lead Question custom metadata record.'
                );
            }

            return buildContext(record, mergeConfiguredQuestions(record, config));
        } catch (Exception e) {
            throw userFacing(e, 'Unable to load the matter specific questions.');
        }
    }

    /**
     * Persists the questionnaire, overwriting all slots.
     *
     * Every slot the client did not send is set to null -- both question and
     * answer -- so a Lead never keeps questions from a previous Matter Type. A
     * question sent without an answer is saved with a null answer; the question
     * itself is still recorded.
     *
     * Only the 30 questionnaire fields are ever written. The client sends question
     * text and answers, never an SObject, so it cannot reach any other field on
     * the Lead.
     *
     * @return the questionnaire re-read from the database after the update.
     */
    @AuraEnabled
    public static LeadQAContext saveAnswers(Id recordId, List<QuestionAnswer> questions) {
        try {
            Lead existing = fetchLead(recordId);

            Lead toUpdate = new Lead(Id = existing.Id);
            Map<Integer, QuestionAnswer> suppliedBySlot = validate(questions);

            for (Integer slot : SLOTS) {
                QuestionAnswer supplied = suppliedBySlot.get(slot);
                Boolean hasQuestion = supplied != null && String.isNotBlank(supplied.question);

                toUpdate.put(
                    QUESTION_FIELD_BY_SLOT.get(slot),
                    hasQuestion ? supplied.question.trim() : null
                );
                toUpdate.put(
                    ANSWER_FIELD_BY_SLOT.get(slot),
                    hasQuestion && String.isNotBlank(supplied.answer)
                        ? supplied.answer.trim()
                        : null
                );
            }

            // `as user` enforces object permissions, field-level security and
            // record sharing for this DML, independently of the class keyword.
            update as user toUpdate;

            Lead saved = fetchLead(recordId);
            return buildContext(saved, storedQuestions(saved));
        } catch (Exception e) {
            throw userFacing(e, 'Unable to save the answers.');
        }
    }

    // ---------------------------------------------------------------------
    // Query helpers
    // ---------------------------------------------------------------------

    /**
     * Reads the Lead under the running user's permissions.
     *
     * The SELECT list is built in the static initialiser from a literal prefix
     * and the integers 1-15, then validated against the Lead describe. No caller
     * input reaches the query string; `recordId` is passed as a bind and is
     * type-checked as a Lead Id first, so a client cannot substitute another
     * object's Id.
     */
    private static Lead fetchLead(Id recordId) {
        assertLeadId(recordId);

        List<Lead> records = (List<Lead>) Database.queryWithBinds(
            LEAD_QUERY,
            new Map<String, Object>{ 'leadId' => recordId },
            AccessLevel.USER_MODE
        );
        if (records.isEmpty()) {
            throw new QuestionnaireException(
                'This Lead no longer exists, or you do not have access to it.'
            );
        }
        return records[0];
    }

    /**
     * Resolves the configured question set: the Sub Type specific record when one
     * exists, otherwise the Matter Type level record. Returns null when neither
     * is configured.
     *
     * SOQL against a Custom Metadata Type does not count toward the query limit,
     * so trying the specific record before the general one is free.
     */
    private static Lead_Question__mdt findQuestionConfig(String matterType, String subType) {
        if (isRealSubType(subType)) {
            Lead_Question__mdt specific = firstConfig(matterType, subType);
            if (specific != null) {
                return specific;
            }
        }
        return firstConfig(matterType, null);
    }

    private static Lead_Question__mdt firstConfig(String matterType, String subType) {
        if (mockQuestionConfigs != null) {
            return filterMocks(matterType, subType);
        }

        List<Lead_Question__mdt> configs;
        if (subType == null) {
            // Matter Type level record: no sub type, or the explicit "N/A" marker.
            configs = [
                SELECT Matter_Type__c, Sub_Type__c,
                       Question_1__c, Question_2__c, Question_3__c, Question_4__c,
                       Question_5__c, Question_6__c, Question_7__c, Question_8__c,
                       Question_9__c, Question_10__c, Question_11__c, Question_12__c,
                       Question_13__c, Question_14__c, Question_15__c
                FROM Lead_Question__mdt
                WHERE Matter_Type__c = :matterType
                  AND (Sub_Type__c = NULL OR Sub_Type__c = :NA_SUB_TYPE)
                ORDER BY Label
                LIMIT 1
            ];
        } else {
            configs = [
                SELECT Matter_Type__c, Sub_Type__c,
                       Question_1__c, Question_2__c, Question_3__c, Question_4__c,
                       Question_5__c, Question_6__c, Question_7__c, Question_8__c,
                       Question_9__c, Question_10__c, Question_11__c, Question_12__c,
                       Question_13__c, Question_14__c, Question_15__c
                FROM Lead_Question__mdt
                WHERE Matter_Type__c = :matterType
                  AND Sub_Type__c = :subType
                ORDER BY Label
                LIMIT 1
            ];
        }
        return configs.isEmpty() ? null : configs[0];
    }

    private static Lead_Question__mdt filterMocks(String matterType, String subType) {
        for (Lead_Question__mdt config : mockQuestionConfigs) {
            if (config.Matter_Type__c != matterType) {
                continue;
            }
            Boolean isTypeLevel = String.isBlank(config.Sub_Type__c)
                || config.Sub_Type__c == NA_SUB_TYPE;
            if (subType == null ? isTypeLevel : config.Sub_Type__c == subType) {
                return config;
            }
        }
        return null;
    }

    // ---------------------------------------------------------------------
    // Assembly
    // ---------------------------------------------------------------------

    /** The questions currently stored on the Lead, skipping empty slots. */
    private static List<QuestionAnswer> storedQuestions(Lead record) {
        List<QuestionAnswer> rows = new List<QuestionAnswer>();
        for (Integer slot : SLOTS) {
            String question = (String) record.get(QUESTION_FIELD_BY_SLOT.get(slot));
            if (String.isBlank(question)) {
                continue;
            }
            rows.add(new QuestionAnswer(
                slot,
                question,
                (String) record.get(ANSWER_FIELD_BY_SLOT.get(slot))
            ));
        }
        return rows;
    }

    /**
     * Builds the draft question list from the configured metadata, carrying over
     * an existing answer only where the identical question is still asked.
     */
    private static List<QuestionAnswer> mergeConfiguredQuestions(
        Lead record,
        Lead_Question__mdt config
    ) {
        Map<String, String> answerByQuestion = new Map<String, String>();
        for (QuestionAnswer stored : storedQuestions(record)) {
            String key = normalise(stored.question);
            // First slot wins if the same question text somehow occupies two slots.
            if (String.isNotBlank(stored.answer) && !answerByQuestion.containsKey(key)) {
                answerByQuestion.put(key, stored.answer);
            }
        }

        List<QuestionAnswer> rows = new List<QuestionAnswer>();
        Integer slot = 0;
        // Read every metadata position, not just the ones the Lead happens to have
        // fields for -- the two numberings are independent. Configured questions
        // are then renumbered into slots 1..n so the Lead never has gaps, whatever
        // gaps the metadata record has.
        for (Integer configuredSlot = 1; configuredSlot <= MAX_SLOTS; configuredSlot++) {
            String question = (String) config.get('Question_' + configuredSlot + '__c');
            if (String.isBlank(question)) {
                continue;
            }
            slot++;
            if (slot > SLOTS.size()) {
                throw new QuestionnaireException(
                    'The question set for Matter Type "' + config.Matter_Type__c +
                    '" defines more questions than the ' + SLOTS.size() +
                    ' this Lead can store. Ask an administrator to shorten it.'
                );
            }
            rows.add(new QuestionAnswer(
                slot,
                question.trim(),
                answerByQuestion.get(normalise(question))
            ));
        }
        return rows;
    }

    private static LeadQAContext buildContext(Lead record, List<QuestionAnswer> questions) {
        LeadQAContext context = new LeadQAContext();
        context.recordId = record.Id;
        context.matterType = record.Matter_Type__c;
        context.matterSubType = record.Matter_Sub_Type__c;
        context.hasMatterType = String.isNotBlank(record.Matter_Type__c);
        context.isEditable = ANSWERS_UPDATEABLE;
        context.slotCount = SLOTS.size();
        context.questionMaxLength = QUESTION_MAX_LENGTH;
        context.answerMaxLength = ANSWER_MAX_LENGTH;
        context.questions = questions;
        return context;
    }

    // ---------------------------------------------------------------------
    // Validation
    // ---------------------------------------------------------------------

    /**
     * Checks the payload before any DML. `@AuraEnabled` methods are reachable by
     * any authenticated user of the org, so the client's slot numbers and lengths
     * are validated here rather than trusted because the component enforces them.
     */
    private static Map<Integer, QuestionAnswer> validate(List<QuestionAnswer> questions) {
        Map<Integer, QuestionAnswer> bySlot = new Map<Integer, QuestionAnswer>();
        if (questions == null) {
            return bySlot;
        }
        if (questions.size() > SLOTS.size()) {
            throw new QuestionnaireException(
                'This Lead can hold at most ' + SLOTS.size() +
                ' questions, but ' + questions.size() + ' were submitted.'
            );
        }

        for (QuestionAnswer row : questions) {
            if (row == null || String.isBlank(row.question)) {
                continue;
            }
            if (row.slot == null || !QUESTION_FIELD_BY_SLOT.containsKey(row.slot)) {
                throw new QuestionnaireException(
                    'Question position "' + row.slot + '" is not valid on this Lead.'
                );
            }
            if (bySlot.containsKey(row.slot)) {
                throw new QuestionnaireException(
                    'Question position ' + row.slot + ' was submitted more than once.'
                );
            }
            if (row.question.trim().length() > QUESTION_MAX_LENGTH) {
                throw new QuestionnaireException(
                    'Question ' + row.slot + ' is longer than the ' +
                    QUESTION_MAX_LENGTH + ' characters the field allows.'
                );
            }
            // Reject rather than truncate: silently cutting an answer in half is
            // data loss the user would not discover until they read it back.
            if (String.isNotBlank(row.answer) && row.answer.trim().length() > ANSWER_MAX_LENGTH) {
                throw new QuestionnaireException(
                    'The answer to question ' + row.slot + ' is ' +
                    row.answer.trim().length() + ' characters. The maximum is ' +
                    ANSWER_MAX_LENGTH + '.'
                );
            }
            bySlot.put(row.slot, row);
        }
        return bySlot;
    }

    private static void assertLeadId(Id recordId) {
        if (recordId == null || recordId.getSObjectType() != Lead.SObjectType) {
            throw new QuestionnaireException('A valid Lead record Id is required.');
        }
        if (SLOTS.isEmpty()) {
            throw new QuestionnaireException(
                'The Question and Answer fields are not deployed on Lead in this org.'
            );
        }
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /**
     * Converts an exception into one the component can display.
     *
     * `QuestionnaireException` and `DmlException` messages are shown as-is: the
     * first is written for the user, and the second carries the org's own
     * validation rule and required field messages, which are exactly what the
     * user needs to fix the record. Anything else is replaced with a generic
     * message so internal detail never reaches the browser.
     *
     * `setMessage` is required as well as the constructor argument -- without it
     * the client receives "Script-thrown exception" instead of the text.
     */
    private static AuraHandledException userFacing(Exception e, String fallback) {
        if (e instanceof AuraHandledException) {
            return (AuraHandledException) e;
        }

        String message = (e instanceof QuestionnaireException || e instanceof DmlException)
            ? e.getMessage()
            : fallback;

        // TODO: route to the org's durable logging framework. System.debug is not
        // production logging -- it is invisible unless someone is holding a trace.
        System.debug(
            LoggingLevel.ERROR,
            'LeadQAController: ' + e.getTypeName() + ' at line ' +
            e.getLineNumber() + ': ' + e.getMessage()
        );

        AuraHandledException handled = new AuraHandledException(message);
        handled.setMessage(message);
        return handled;
    }

    /** Signals a condition the user can understand and act on. */
    public class QuestionnaireException extends Exception {}

    // ---------------------------------------------------------------------
    // Small helpers
    // ---------------------------------------------------------------------

    private static Boolean isRealSubType(String subType) {
        return String.isNotBlank(subType) && subType != NA_SUB_TYPE;
    }

    private static String normalise(String value) {
        return value == null ? '' : value.trim().toLowerCase();
    }

    private static Integer min(Integer current, Integer candidate) {
        if (candidate == null || candidate <= 0) {
            return current;
        }
        return current == null ? candidate : Math.min(current, candidate);
    }

    // ---------------------------------------------------------------------
    // Transfer objects
    // ---------------------------------------------------------------------

    /** One question and its answer, at a 1-based position on the Lead. */
    public class QuestionAnswer {
        @AuraEnabled public Integer slot { get; set; }
        @AuraEnabled public String question { get; set; }
        @AuraEnabled public String answer { get; set; }

        /** Required so the platform can deserialise the LWC payload. */
        public QuestionAnswer() {}

        public QuestionAnswer(Integer slot, String question, String answer) {
            this.slot = slot;
            this.question = question;
            this.answer = answer;
        }
    }

    /** Everything the component needs for one render. */
    public class LeadQAContext {
        @AuraEnabled public Id recordId { get; set; }
        @AuraEnabled public String matterType { get; set; }
        @AuraEnabled public String matterSubType { get; set; }
        @AuraEnabled public Boolean hasMatterType { get; set; }
        @AuraEnabled public Boolean isEditable { get; set; }
        @AuraEnabled public Integer slotCount { get; set; }
        @AuraEnabled public Integer questionMaxLength { get; set; }
        @AuraEnabled public Integer answerMaxLength { get; set; }
        @AuraEnabled public List<QuestionAnswer> questions { get; set; }
    }
}
