import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { notifyRecordUpdateAvailable } from 'lightning/uiRecordApi';
import LightningConfirm from 'lightning/confirm';

import getLeadQA from '@salesforce/apex/LeadQAController.getLeadQA';
import getMatterQuestions from '@salesforce/apex/LeadQAController.getMatterQuestions';
import saveAnswers from '@salesforce/apex/LeadQAController.saveAnswers';

const DEFAULT_MAX_LENGTH = 255;
/** Show a character counter only once the answer is close to the field limit. */
const COUNTER_THRESHOLD = 0.8;

/**
 * Reduces the several shapes an Apex/LDS error arrives in down to one string.
 * An unhandled error object rendered directly shows "[object Object]".
 */
function reduceError(error) {
    if (!error) {
        return '';
    }
    if (Array.isArray(error.body)) {
        return error.body.map((e) => e.message).join(', ');
    }
    if (error.body && typeof error.body.message === 'string') {
        return error.body.message;
    }
    if (typeof error.message === 'string') {
        return error.message;
    }
    return 'An unexpected error occurred.';
}

export default class LeadQuestionAnswer extends LightningElement {
    @api recordId;

    context;
    /** Working copy: `{ slot, question, answer }`, edited before it is saved. */
    draft = [];
    /** The last saved state, so dirty checking compares against the database. */
    baseline = [];

    isLoadingQuestions = false;
    isSaving = false;
    errorMessage = '';
    statusMessage = '';
    lastSavedAt;

    /** Kept whole, not just `.data` -- `refreshApex` needs the wired result. */
    wiredResult;

    @wire(getLeadQA, { recordId: '$recordId' })
    wiredLeadQA(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.errorMessage = '';
            this.applyContext(data, data.questions);
        } else if (error) {
            // A wire with no error branch renders a permanently blank component.
            this.errorMessage = reduceError(error);
        }
    }

    // -----------------------------------------------------------------
    // Actions
    // -----------------------------------------------------------------

    async handleLoadQuestions() {
        // Reloading replaces every question, so any answer whose question is not
        // in the new set is discarded. Say so before the work is lost, not after.
        if (this.answeredCount > 0) {
            const proceed = await LightningConfirm.open({
                label: 'Reload matter questions',
                message:
                    `This replaces the current questions with the set configured for ` +
                    `${this.matterLabel}. Answers are kept only where the same question ` +
                    `is still asked; the other ${this.answeredCount} will be cleared.`,
                theme: 'warning',
                variant: 'header'
            });
            if (!proceed) {
                return;
            }
        }

        this.isLoadingQuestions = true;
        this.errorMessage = '';
        try {
            const context = await getMatterQuestions({ recordId: this.recordId });
            this.applyContext(context, context.questions, { keepBaseline: true });
            this.statusMessage = `${this.questionCount} questions loaded. Not saved yet.`;
        } catch (error) {
            this.errorMessage = reduceError(error);
            this.statusMessage = 'Could not load the questions.';
        } finally {
            // Cleared in `finally`, never in both branches -- it is the branch you
            // forget that leaves the spinner running forever.
            this.isLoadingQuestions = false;
        }
    }

    async handleSave() {
        this.isSaving = true;
        this.errorMessage = '';
        try {
            const context = await saveAnswers({
                recordId: this.recordId,
                questions: this.draft.map(({ slot, question, answer }) => ({
                    slot,
                    question,
                    answer: answer || null
                }))
            });

            this.applyContext(context, context.questions);
            this.lastSavedAt = new Date();
            this.statusMessage = 'Answers saved.';

            // Keep the wire cache and the rest of the record page in step with
            // what was just written.
            notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
            if (this.wiredResult) {
                await refreshApex(this.wiredResult);
            }

            this.toast('Saved', 'The matter questions were saved.', 'success');
        } catch (error) {
            const message = reduceError(error);
            this.errorMessage = message;
            this.statusMessage = 'Save failed.';
            this.toast('Save failed', message, 'error', 'sticky');
        } finally {
            this.isSaving = false;
        }
    }

    handleAnswerChange(event) {
        const slot = Number(event.target.dataset.slot);
        const value = event.detail.value;
        // Reassign rather than mutate: an in-place edit does not re-render.
        this.draft = this.draft.map((row) => {
            return row.slot === slot ? { ...row, answer: value } : row;
        });
    }

    // -----------------------------------------------------------------
    // State
    // -----------------------------------------------------------------

    /**
     * @param {object} context   the LeadQAContext from Apex
     * @param {Array}  questions the question rows to show
     * @param {object} options   `keepBaseline` leaves the saved-state comparison
     *                           alone, so a freshly loaded but unsaved question
     *                           set correctly reads as dirty.
     */
    applyContext(context, questions, options = {}) {
        this.context = context;
        this.draft = (questions || []).map((row) => ({
            slot: row.slot,
            question: row.question,
            answer: row.answer || ''
        }));
        if (!options.keepBaseline) {
            this.baseline = this.draft.map((row) => ({ ...row }));
        }
    }

    toast(title, message, variant, mode = 'dismissable') {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
    }

    // -----------------------------------------------------------------
    // Derived state
    // -----------------------------------------------------------------

    get questions() {
        const max = this.answerMaxLength;
        return this.draft.map((row) => {
            const length = row.answer ? row.answer.length : 0;
            const isUnanswered = length === 0;
            return {
                ...row,
                isUnanswered,
                remaining: max - length,
                showCounter: length >= max * COUNTER_THRESHOLD,
                itemClass: isUnanswered
                    ? 'slds-item question-row question-row_unanswered'
                    : 'slds-item question-row',
                badgeClass: isUnanswered ? 'slot-badge' : 'slot-badge slot-badge_answered'
            };
        });
    }

    get questionCount() {
        return this.draft.length;
    }

    get answeredCount() {
        return this.draft.filter((row) => row.answer && row.answer.trim()).length;
    }

    get hasQuestions() {
        return this.questionCount > 0;
    }

    get answerMaxLength() {
        return this.context?.answerMaxLength || DEFAULT_MAX_LENGTH;
    }

    get tooLongMessage() {
        return `Answers are limited to ${this.answerMaxLength} characters.`;
    }

    get matterLabel() {
        if (!this.context?.matterType) {
            return '';
        }
        const { matterType, matterSubType } = this.context;
        return matterSubType && matterSubType !== 'N/A'
            ? `${matterType} / ${matterSubType}`
            : matterType;
    }

    get isReadOnly() {
        return this.context ? !this.context.isEditable : true;
    }

    get isBusy() {
        return this.isLoadingQuestions || this.isSaving;
    }

    get busyMessage() {
        return this.isSaving ? 'Saving' : 'Loading questions';
    }

    get isDirty() {
        if (this.draft.length !== this.baseline.length) {
            return true;
        }
        return this.draft.some((row, index) => {
            const saved = this.baseline[index];
            return (
                !saved ||
                saved.slot !== row.slot ||
                saved.question !== row.question ||
                (saved.answer || '') !== (row.answer || '')
            );
        });
    }

    get isLoadDisabled() {
        return this.isBusy || !this.context?.hasMatterType || this.isReadOnly;
    }

    get isSaveDisabled() {
        return this.isBusy || this.isReadOnly || !this.isDirty;
    }

    get showMatterTypePrompt() {
        return !!this.context && !this.context.hasMatterType;
    }

    get showEmptyState() {
        return !!this.context && this.context.hasMatterType && !this.hasQuestions;
    }

    get showReadOnlyNotice() {
        return !!this.context && this.isReadOnly;
    }

    get progressStyle() {
        const percent = this.questionCount
            ? Math.round((this.answeredCount / this.questionCount) * 100)
            : 0;
        return `width: ${percent}%;`;
    }

    get footerMessage() {
        if (this.isDirty) {
            return 'You have unsaved changes. Choose Save to write them to the Lead.';
        }
        if (this.lastSavedAt) {
            return `Saved at ${this.lastSavedAt.toLocaleTimeString()}.`;
        }
        return `${this.questionCount} questions stored on this Lead.`;
    }
}
