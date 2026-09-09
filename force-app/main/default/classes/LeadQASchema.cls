/**
 * Describes the Lead questionnaire slots once per transaction.
 *
 * The questionnaire occupies 15 paired `Question_N__c` / `Answer_N__c` fields.
 * Their API names follow a compile-time pattern, but an org may not have all 15
 * deployed, so they are resolved against the Lead describe rather than assumed.
 * A missing field then degrades gracefully instead of throwing an opaque
 * "No such column" at runtime.
 *
 * This is schema introspection, deliberately kept apart from
 * `LeadQAController`, which handles requests. Everything here is computed once
 * in a static initialiser and read many times.
 *
 * `with sharing` is inherited by nothing here -- this class touches only
 * describe information, never records.
 */
public with sharing class LeadQASchema {

    /** Number of Question/Answer slots the questionnaire is designed around. */
    public static final Integer MAX_SLOTS = 15;

    /** Slot number -> `Question_N__c` API name, for slots that exist in this org. */
    public static final Map<Integer, String> QUESTION_FIELD_BY_SLOT;

    /** Slot number -> `Answer_N__c` API name, for slots that exist in this org. */
    public static final Map<Integer, String> ANSWER_FIELD_BY_SLOT;

    /** Slot numbers present in this org, ascending. */
    public static final List<Integer> SLOTS;

    /** Shortest `Question_N__c` length. */
    public static final Integer QUESTION_MAX_LENGTH;

    /** Shortest `Answer_N__c` length, so the UI can cap input before DML fails. */
    public static final Integer ANSWER_MAX_LENGTH;

    /** True when the running user may update Lead and every Answer field. */
    public static final Boolean ANSWERS_UPDATEABLE;

    /**
     * `SELECT` over the slot fields, bound on `:leadId`.
     *
     * Built here from a literal prefix and the integers 1-15, then validated
     * against the describe. No caller input reaches it, so the dynamic query it
     * feeds carries no injection surface.
     */
    public static final String LEAD_QUERY;

    private static final Integer DEFAULT_FIELD_LENGTH = 255;

    static {
        Map<Integer, String> questionFields = new Map<Integer, String>();
        Map<Integer, String> answerFields = new Map<Integer, String>();
        List<Integer> slots = new List<Integer>();

        Integer questionLength = null;
        Integer answerLength = null;
        Boolean answersUpdateable = true;

        Map<String, Schema.SObjectField> fieldsByLowerName = leadFieldsByLowerName();

        for (Integer slot = 1; slot <= MAX_SLOTS; slot++) {
            Schema.SObjectField questionField =
                fieldsByLowerName.get(('Question_' + slot + '__c').toLowerCase());
            Schema.SObjectField answerField =
                fieldsByLowerName.get(('Answer_' + slot + '__c').toLowerCase());
            if (questionField == null || answerField == null) {
                continue;
            }

            // 15 field describes in a static initialiser: once per transaction,
            // not per record. Field describes are cheap; `getGlobalDescribe()` is
            // not, and is deliberately avoided.
            Schema.DescribeFieldResult questionInfo = questionField.getDescribe();
            Schema.DescribeFieldResult answerInfo = answerField.getDescribe();

            questionLength = smaller(questionLength, questionInfo.getLength());
            answerLength = smaller(answerLength, answerInfo.getLength());
            answersUpdateable = answersUpdateable && answerInfo.isUpdateable();

            slots.add(slot);
            questionFields.put(slot, questionInfo.getName());
            answerFields.put(slot, answerInfo.getName());
        }

        QUESTION_FIELD_BY_SLOT = questionFields;
        ANSWER_FIELD_BY_SLOT = answerFields;
        SLOTS = slots;
        QUESTION_MAX_LENGTH = questionLength == null ? DEFAULT_FIELD_LENGTH : questionLength;
        ANSWER_MAX_LENGTH = answerLength == null ? DEFAULT_FIELD_LENGTH : answerLength;
        ANSWERS_UPDATEABLE = answersUpdateable
            && !slots.isEmpty()
            && Schema.SObjectType.Lead.isUpdateable();
        LEAD_QUERY = buildLeadQuery(questionFields, answerFields);
    }

    /**
     * Lead's fields keyed by lower-cased API name. `getMap()` is a describe call,
     * so it is issued once; the keys are lower-cased because `getMap()` does not
     * promise their casing and `Map<String, ...>` lookups are case sensitive.
     */
    private static Map<String, Schema.SObjectField> leadFieldsByLowerName() {
        Map<String, Schema.SObjectField> leadFields = Schema.SObjectType.Lead.fields.getMap();
        Map<String, Schema.SObjectField> byLowerName =
            new Map<String, Schema.SObjectField>();
        for (String name : leadFields.keySet()) {
            byLowerName.put(name.toLowerCase(), leadFields.get(name));
        }
        return byLowerName;
    }

    private static String buildLeadQuery(
        Map<Integer, String> questionFields,
        Map<Integer, String> answerFields
    ) {
        List<String> selectFields = new List<String>{
            'Id', 'Name', 'Matter_Type__c', 'Matter_Sub_Type__c'
        };
        selectFields.addAll(questionFields.values());
        selectFields.addAll(answerFields.values());
        return 'SELECT ' + String.join(selectFields, ', ') +
               ' FROM Lead WHERE Id = :leadId LIMIT 1';
    }

    /** The smaller of two lengths, ignoring nulls and non-positive values. */
    private static Integer smaller(Integer current, Integer candidate) {
        if (candidate == null || candidate <= 0) {
            return current;
        }
        return current == null ? candidate : Math.min(current, candidate);
    }
}
