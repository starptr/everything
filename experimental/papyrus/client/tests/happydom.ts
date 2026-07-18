// First preload: register happy-dom's globals (document/window/...) BEFORE any
// other preload or test imports @testing-library, whose `screen` binds to
// `document` eagerly at import time. Kept separate from setup.ts because import
// hoisting would otherwise evaluate Testing Library before register() runs.
import { GlobalRegistrator } from "@happy-dom/global-registrator";

GlobalRegistrator.register();
