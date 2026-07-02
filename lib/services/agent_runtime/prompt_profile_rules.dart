/// Profile/soul persistence rules shared by analyzer and fast chat routing.
library;

const promptProfilePersistenceRules = '''PROFILE PERSISTENCE RULES:
- User identity/profile data is durable state. If the user provides or changes their name, nickname, timezone, work role, main project, communication style, design preference, or preferred language, the request requires the full agentic runtime.
- Persist the smallest relevant field with system.profile.update. Do not answer as ordinary chat and do not store profile data as memory or files.
- For system.profile.update, use the tool's API field keys exactly: name, nickname, preferred_language, timezone, work_role, main_project, communication_style, design_preference, persona. SQLite column names such as user_name and user_nickname are storage details, not valid tool arguments.
- If the user is responding to an introduction/name question and gives a plausible name or nickname, treat it as a profile update even if the message is short.
- If the user clearly declines to introduce themselves or asks a normal question instead, do not invent profile data.''';
