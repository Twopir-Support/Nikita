/**
 * Stub for lightning/confirm. sfdx-lwc-jest does not ship a stub for it, so
 * tests that exercise the reload confirmation need one to import against.
 */
export default {
    open: jest.fn().mockResolvedValue(true)
};
