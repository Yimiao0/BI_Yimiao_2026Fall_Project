# Plan: connect the Shiny app on Posit Connect to the Copilot Studio agent

Goal: when a user clicks **Test the agent on 10 papers** or **Run the agent** in step 2, the app sends the papers to the Copilot Studio agent as that user, and gets the agent's replies back.

Already done: the app runs on Posit Connect (`/trial-data-collection/`), the agent is built and published in Copilot Studio, and its connection string has been copied.

## Steps

| # | Who | What | Status |
|---|---|---|---|
| 1 | You | Add the environment variable `COPILOT_CONNECTION_STRING` on Connect (Settings → Advanced → Environment Variables). Value: the `https://...conversations?api-version=2022-03-01-preview` link from Copilot Studio → Channels → App. | Can do now |
| 2 | You | Send the request to IT / the Posit Connect administrator (see "What to ask IT" below). | Can do now |
| 3 | IT (Entra ID admin) | Create the app registration, add the permission, give admin consent, create a client secret, add Connect's redirect URI. | Waiting on IT |
| 4 | Connect administrator | Create the Microsoft Entra ID OAuth integration on Connect, using the app registration from step 3. | Waiting on IT |
| 5 | You | Attach the integration to the app: Settings → Access → Integrations. | After 4 |
| 6 | You | Add the environment variable `AGENT_BACKEND` = `copilot`. | After 5 |
| 7 | You | Open the app, run step 1, then click **Test the agent on 10 papers**. Sign in to Microsoft when asked (first time only). | After 6 |
| 8 | You | When it works: share the agent in Copilot Studio with the colleagues who will use step 2. | Later |

Steps 3 and 4 are often done by the same team. Ask whether Connect has **Python 3.10 or later** at the same time; the app needs it to talk to the agent.

## What to ask IT

1. An **Entra ID app registration** with:
   - the delegated API permission **Power Platform API → `CopilotStudio.Copilots.Invoke`**, with admin consent
   - a client secret
   - Posit Connect's OAuth redirect URI
2. A **Microsoft Entra ID OAuth integration** on Posit Connect, using that registration, with the scopes `https://api.powerplatform.com/.default` and `offline_access`, that I can attach to my app.
3. Confirmation that Python 3.10 or later is available on Connect.

## Terms

**Microsoft Entra ID** (formerly Azure Active Directory): the company's Microsoft account system, the one behind your work login. It decides who and what may use Microsoft services.

**App registration**: an ID card for our app inside Entra ID. Microsoft only lets an app call its services (here, Copilot Studio) if the app is registered. It has:
- **Tenant ID**: the ID of your company's Entra ID.
- **Client ID** (application ID): the ID of the registered app.
- **Client secret**: a password for the app. Only IT and Connect see it; it never goes into the app's code or GitHub.

**Permission** (API permission): what the registered app is allowed to do. We need one:
- **Power Platform API**: the Microsoft service that runs Copilot Studio agents.
- **`CopilotStudio.Copilots.Invoke`**: the permission to send messages to Copilot Studio agents.
- **Delegated**: the app acts *as the signed-in user*, with only that user's access. It can only reach agents that user is allowed to use.
- **Admin consent**: an admin's approval of the permission for the whole company. Normal users can't give it, which is why IT is needed.

**OAuth**: the standard way for one app to act on your behalf in another service without seeing your password. You sign in with Microsoft once, and the app gets a token.

**Token** (access token): a short-lived pass that says "this app may call Copilot Studio for this user". Connect gets it and refreshes it; the app uses it for each message to the agent.

**OAuth integration** (on Posit Connect): a setting the Connect administrator creates once from the app registration. It lets Connect run the Microsoft sign-in for an app and hand the app the user's token. It must be **attached** to each app that uses it (Settings → Access → Integrations).

**Redirect URI**: the web address Microsoft sends the user back to after they sign in. For us it's a Connect address; the Connect administrator knows it.

**Scope**: what the token is good for.
- `https://api.powerplatform.com/.default`: the token is for the Power Platform API, with the permissions given to the app registration.
- `offline_access`: Connect may renew the token without asking the user to sign in again.

**Environment variable**: a setting with a name and a value, stored on Connect (Settings → Advanced → Environment Variables), that the app reads when it starts. Used so the settings stay out of the code and out of GitHub.
- `COPILOT_CONNECTION_STRING`: the address of the agent.
- `AGENT_BACKEND`: which agent step 2 uses. Unset = the placeholder agent that makes up rows; `copilot` = the Copilot Studio agent.

**Connection string**: the agent's address, from Copilot Studio → Channels → App (Microsoft 365 Agents SDK). Not a password, but keep it out of GitHub.

**Python SDK** (Microsoft 365 Agents SDK): Microsoft's code library for talking to Copilot Studio agents. The app (written in R) uses it through the R package `reticulate`.

## If something goes wrong

- **Sign-in error in step 2**: the integration isn't attached (step 5), or `AGENT_BACKEND` was set before it was.
- **"Forbidden" or permission error**: the permission or admin consent in step 3 is missing, or the user has no access to the agent (step 8).
- **The agent can't be found**: check `COPILOT_CONNECTION_STRING` was copied in full, and that the agent is published.
- **Python error at start-up**: Python isn't available on Connect (ask IT).
