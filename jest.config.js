const { jestConfig } = require('@salesforce/sfdx-lwc-jest/config');

module.exports = {
    ...jestConfig,
    moduleNameMapper: {
        '^lightning/confirm$': '<rootDir>/force-app/test/jest-mocks/lightning/confirm'
    }
};
