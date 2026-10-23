// The page itself: every rule Autoconsent has.
import AutoConsent, { filterCompactRules } from '@duckduckgo/autoconsent';
import rules from '@duckduckgo/autoconsent/rules/compact-rules.json';
import { start } from './bridge.js';

if (window.top === window) start(AutoConsent, filterCompactRules, rules);
