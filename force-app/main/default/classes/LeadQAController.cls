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

            Lead_Question__mdt config = LeadQuestionSelector.findFor(
                record.Matter_Type__c,
                record.Matter_Sub_Type__c
            );
            if (config == null) {
                throw new QuestionnaireException(
                    'No question set is configured for Matter Type "' +
                    record.Matter_Type__c + '"' +
                    (LeadQuestionSelector.isRealSubType(record.Matter_Sub_Type__c)
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

            for (Integer slot : LeadQASchema.SLOTS) {
                QuestionAnswer supplied = suppliedBySlot.get(slot);
                Boolean hasQuestion = supplied != null && String.isNotBlank(supplied.question);

                toUpdate.put(
                    LeadQASchema.QUESTION_FIELD_BY_SLOT.get(slot),
                    hasQuestion ? supplied.question.trim() : null
                );
                toUpdate.put(
                    LeadQASchema.ANSWER_FIELD_BY_SLOT.get(slot),
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
            LeadQASchema.LEAD_QUERY,
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

    // ---------------------------------------------------------------------
    // Assembly
    // ---------------------------------------------------------------------

    /** The questions currently stored on the Lead, skipping empty slots. */
    private static List<QuestionAnswer> storedQuestions(Lead record) {
        List<QuestionAnswer> rows = new List<QuestionAnswer>();
        for (Integer slot : LeadQASchema.SLOTS) {
            String question = (String) record.get(LeadQASchema.QUESTION_FIELD_BY_SLOT.get(slot));
            if (String.isBlank(question)) {
                continue;
            }
            rows.add(new QuestionAnswer(
                slot,
                question,
                (String) record.get(LeadQASchema.ANSWER_FIELD_BY_SLOT.get(slot))
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
        for (Integer configuredSlot = 1; configuredSlot <= LeadQASchema.MAX_SLOTS; configuredSlot++) {
            String question = (String) config.get('Question_' + configuredSlot + '__c');
            if (String.isBlank(question)) {
                continue;
            }
            slot++;
            if (slot > LeadQASchema.SLOTS.size()) {
                throw new QuestionnaireException(
                    'The question set for Matter Type "' + config.Matter_Type__c +
                    '" defines more questions than the ' + LeadQASchema.SLOTS.size() +
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
        context.isEditable = LeadQASchema.ANSWERS_UPDATEABLE;
        context.slotCount = LeadQASchema.SLOTS.size();
        context.questionMaxLength = LeadQASchema.QUESTION_MAX_LENGTH;
        context.answerMaxLength = LeadQASchema.ANSWER_MAX_LENGTH;
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
        if (questions.size() > LeadQASchema.SLOTS.size()) {
            throw new QuestionnaireException(
                'This Lead can hold at most ' + LeadQASchema.SLOTS.size() +
                ' questions, but ' + questions.size() + ' were submitted.'
            );
        }

        for (QuestionAnswer row : questions) {
            if (row == null || String.isBlank(row.question)) {
                continue;
            }
            validateRow(row, bySlot);
            bySlot.put(row.slot, row);
        }
        return bySlot;
    }

    /** Per-row checks, split out of `validate` to keep both readable. */
    private static void validateRow(QuestionAnswer row, Map<Integer, QuestionAnswer> seen) {
        if (row.slot == null || !LeadQASchema.QUESTION_FIELD_BY_SLOT.containsKey(row.slot)) {
            throw new QuestionnaireException(
                'Question position "' + row.slot + '" is not valid on this Lead.'
            );
        }
        if (seen.containsKey(row.slot)) {
            throw new QuestionnaireException(
                'Question position ' + row.slot + ' was submitted more than once.'
            );
        }
        validateLengths(row);
    }

    /**
     * Rejects text the fields cannot hold, rather than truncating it. Silently
     * cutting an answer in half is data loss the user would not discover until
     * they read it back.
     */
    private static void validateLengths(QuestionAnswer row) {
        if (row.question.trim().length() > LeadQASchema.QUESTION_MAX_LENGTH) {
            throw new QuestionnaireException(
                'Question ' + row.slot + ' is longer than the ' +
                LeadQASchema.QUESTION_MAX_LENGTH + ' characters the field allows.'
            );
        }
        if (String.isBlank(row.answer)) {
            return;
        }
        Integer answerLength = row.answer.trim().length();
        if (answerLength > LeadQASchema.ANSWER_MAX_LENGTH) {
            throw new QuestionnaireException(
                'The answer to question ' + row.slot + ' is ' + answerLength +
                ' characters. The maximum is ' + LeadQASchema.ANSWER_MAX_LENGTH + '.'
            );
        }
    }

    private static void assertLeadId(Id recordId) {
        if (recordId == null || recordId.getSObjectType() != Lead.SObjectType) {
            throw new QuestionnaireException('A valid Lead record Id is required.');
        }
        if (LeadQASchema.SLOTS.isEmpty()) {
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
    @SuppressWarnings('PMD.AvoidDebugStatements')
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

    private static String normalise(String value) {
        return value == null ? '' : value.trim().toLowerCase();
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
        @SuppressWarnings('PMD.EmptyStatementBlock')
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
