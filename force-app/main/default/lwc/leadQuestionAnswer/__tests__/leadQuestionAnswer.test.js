import { createElement } from 'lwc';
import LeadQuestionAnswer from 'c/leadQuestionAnswer';
import getLeadQA from '@salesforce/apex/LeadQAController.getLeadQA';
import getMatterQuestions from '@salesforce/apex/LeadQAController.getMatterQuestions';
import saveAnswers from '@salesforce/apex/LeadQAController.saveAnswers';

jest.mock(
    '@salesforce/apex/LeadQAController.getMatterQuestions',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LeadQAController.saveAnswers',
    () => ({ default: jest.fn() }),
    { virtual: true }
);
jest.mock(
    '@salesforce/apex/LeadQAController.getLeadQA',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);
import LightningConfirm from 'lightning/confirm';

const RECORD_ID = '00Q000000000001AAA';

const context = (overrides = {}) => ({
    recordId: RECORD_ID,
    matterType: 'Personal Injury',
    matterSubType: null,
    hasMatterType: true,
    isEditable: true,
    slotCount: 15,
    questionMaxLength: 255,
    answerMaxLength: 255,
    questions: [],
    ...overrides
});

const flushPromises = () => new Promise((resolve) => setTimeout(resolve, 0));

function build() {
    const element = createElement('c-lead-question-answer', { is: LeadQuestionAnswer });
    element.recordId = RECORD_ID;
    document.body.appendChild(element);
    return element;
}

const buttonLabelled = (element, label) =>
    [...element.shadowRoot.querySelectorAll('lightning-button')].find(
        (b) => b.label === label
    );

describe('c-lead-question-answer', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it('renders the questions already stored on the Lead', async () => {
        const element = build();
        getLeadQA.emit(
            context({
                questions: [
                    { slot: 1, question: 'Where did it happen?', answer: 'Bristol' },
                    { slot: 2, question: 'When did it happen?', answer: null }
                ]
            })
        );
        await flushPromises();

        const inputs = element.shadowRoot.querySelectorAll('lightning-textarea');
        expect(inputs).toHaveLength(2);
        expect(inputs[0].label).toBe('Where did it happen?');
        expect(inputs[0].value).toBe('Bristol');
        expect(inputs[1].value).toBe('');
    });

    it('prompts for a Matter Type and disables loading when none is set', async () => {
        const element = build();
        getLeadQA.emit(context({ hasMatterType: false, matterType: null }));
        await flushPromises();

        expect(element.shadowRoot.querySelector('.slds-theme_warning')).not.toBeNull();
        expect(buttonLabelled(element, 'Get Matter Specific Questions').disabled).toBe(true);
    });

    it('shows an empty state when a Matter Type is set but no questions are stored', async () => {
        const element = build();
        getLeadQA.emit(context());
        await flushPromises();

        expect(element.shadowRoot.querySelector('.empty-state')).not.toBeNull();
        expect(buttonLabelled(element, 'Get Matter Specific Questions').disabled).toBe(false);
    });

    it('surfaces a wire error instead of rendering an empty component', async () => {
        const element = build();
        getLeadQA.error({ message: 'Insufficient access' }, 400);
        await flushPromises();

        const alert = element.shadowRoot.querySelector('[role="alert"]');
        expect(alert).not.toBeNull();
        expect(alert.textContent).toContain('Insufficient access');
    });

    it('replaces every stored question when a shorter set is loaded', async () => {
        const element = build();
        getLeadQA.emit(
            context({
                questions: Array.from({ length: 10 }, (_, i) => ({
                    slot: i + 1,
                    question: `Old question ${i + 1}`,
                    answer: `Old answer ${i + 1}`
                }))
            })
        );
        await flushPromises();
        expect(element.shadowRoot.querySelectorAll('lightning-textarea')).toHaveLength(10);

        LightningConfirm.open.mockResolvedValue(true);
        getMatterQuestions.mockResolvedValue(
            context({
                questions: [
                    { slot: 1, question: 'New question 1', answer: null },
                    { slot: 2, question: 'New question 2', answer: null }
                ]
            })
        );

        buttonLabelled(element, 'Get Matter Specific Questions').click();
        await flushPromises();
        await flushPromises();

        const inputs = element.shadowRoot.querySelectorAll('lightning-textarea');
        expect(inputs).toHaveLength(2);
        expect(inputs[0].label).toBe('New question 1');
        expect([...inputs].every((i) => i.value === '')).toBe(true);
    });

    it('does not reload when the confirmation is declined', async () => {
        const element = build();
        getLeadQA.emit(
            context({ questions: [{ slot: 1, question: 'Q1', answer: 'Answered' }] })
        );
        await flushPromises();

        LightningConfirm.open.mockResolvedValue(false);
        buttonLabelled(element, 'Get Matter Specific Questions').click();
        await flushPromises();

        expect(getMatterQuestions).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('lightning-textarea').value).toBe('Answered');
    });

    it('loads without confirmation when nothing has been answered', async () => {
        const element = build();
        getLeadQA.emit(context());
        await flushPromises();

        getMatterQuestions.mockResolvedValue(
            context({ questions: [{ slot: 1, question: 'Q1', answer: null }] })
        );
        buttonLabelled(element, 'Get Matter Specific Questions').click();
        await flushPromises();

        expect(LightningConfirm.open).not.toHaveBeenCalled();
        expect(getMatterQuestions).toHaveBeenCalledWith({ recordId: RECORD_ID });
    });

    it('sends every question on save, including the ones left unanswered', async () => {
        const element = build();
        getLeadQA.emit(
            context({
                questions: [
                    { slot: 1, question: 'Q1', answer: null },
                    { slot: 2, question: 'Q2', answer: null }
                ]
            })
        );
        await flushPromises();

        const input = element.shadowRoot.querySelector('lightning-textarea');
        input.dispatchEvent(new CustomEvent('change', { detail: { value: 'Typed' } }));
        await flushPromises();

        saveAnswers.mockResolvedValue(
            context({
                questions: [
                    { slot: 1, question: 'Q1', answer: 'Typed' },
                    { slot: 2, question: 'Q2', answer: null }
                ]
            })
        );
        buttonLabelled(element, 'Save').click();
        await flushPromises();

        expect(saveAnswers).toHaveBeenCalledWith({
            recordId: RECORD_ID,
            questions: [
                { slot: 1, question: 'Q1', answer: 'Typed' },
                { slot: 2, question: 'Q2', answer: null }
            ]
        });
    });

    it('keeps Save disabled until something changes, then enables it', async () => {
        const element = build();
        getLeadQA.emit(
            context({ questions: [{ slot: 1, question: 'Q1', answer: 'Stored' }] })
        );
        await flushPromises();
        expect(buttonLabelled(element, 'Save').disabled).toBe(true);

        element.shadowRoot
            .querySelector('lightning-textarea')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'Edited' } }));
        await flushPromises();

        expect(buttonLabelled(element, 'Save').disabled).toBe(false);
    });

    it('shows the save error and clears the spinner when Apex rejects', async () => {
        const element = build();
        getLeadQA.emit(
            context({ questions: [{ slot: 1, question: 'Q1', answer: null }] })
        );
        await flushPromises();

        element.shadowRoot
            .querySelector('lightning-textarea')
            .dispatchEvent(new CustomEvent('change', { detail: { value: 'x' } }));
        await flushPromises();

        saveAnswers.mockRejectedValue({ body: { message: 'Validation rule failed' } });
        buttonLabelled(element, 'Save').click();
        await flushPromises();
        await flushPromises();

        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain(
            'Validation rule failed'
        );
        expect(element.shadowRoot.querySelector('lightning-spinner')).toBeNull();
    });

    it('disables editing and both buttons when the user has read only access', async () => {
        const element = build();
        getLeadQA.emit(
            context({
                isEditable: false,
                questions: [{ slot: 1, question: 'Q1', answer: 'Stored' }]
            })
        );
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-textarea').disabled).toBe(true);
        expect(buttonLabelled(element, 'Save').disabled).toBe(true);
        expect(buttonLabelled(element, 'Get Matter Specific Questions').disabled).toBe(true);
    });

    it('caps answers at the length the Answer field actually allows', async () => {
        const element = build();
        getLeadQA.emit(
            context({
                answerMaxLength: 100,
                questions: [{ slot: 1, question: 'Q1', answer: null }]
            })
        );
        await flushPromises();

        expect(element.shadowRoot.querySelector('lightning-textarea').maxLength).toBe(100);
    });
});
