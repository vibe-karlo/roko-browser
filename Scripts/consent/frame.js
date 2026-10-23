// Frames in the page (Sourcepoint and others draw their pop-up in one): only
// the few rules written for frames, made by build_consent.sh.
import AutoConsent, { filterCompactRules } from '@duckduckgo/autoconsent';
import rules from './frame-rules.json';
import { start } from './bridge.js';

if (window.top !== window) start(AutoConsent, filterCompactRules, rules);
