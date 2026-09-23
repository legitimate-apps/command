"""Public legal + support pages (HTML, no auth).

Apple requires a subscription app to surface functional **Terms (EULA)** and
**Privacy** links, and an AI app to disclose third-party model processing. These
pages back the links shown on the iOS paywall + AI-consent gate. They are static
strings — no template engine, no per-request work, negligible RSS.

Mounted at the root (`/privacy`, `/terms`, `/support`) *before* the MCP catch-all
mount so they match first. Public on purpose: legal pages must be reachable
without an account.
"""

from __future__ import annotations

from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter(tags=["legal"])

_UPDATED = "June 18, 2026"
_CONTACT = "info@legitimateapps.com"
_APPLE_EULA = "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"

_STYLE = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0; padding: 2.5rem 1.25rem 4rem;
  font: 16px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Georgia, serif;
  color: #211c16; background: #f6f2ea;
  -webkit-text-size-adjust: 100%;
}
main { max-width: 44rem; margin: 0 auto; }
h1 { font-size: 1.9rem; font-weight: 600; letter-spacing: -0.01em; margin: 0 0 .25rem; }
h2 { font-size: 1.15rem; font-weight: 600; margin: 2rem 0 .5rem; }
.updated { color: #6b6253; font-size: .9rem; margin: 0 0 2rem; }
p, li { color: #34302a; }
a { color: #b4581b; text-decoration: none; }
a:hover { text-decoration: underline; }
ul { padding-left: 1.2rem; }
li { margin: .3rem 0; }
hr { border: 0; border-top: 1px solid rgba(0,0,0,.1); margin: 2.5rem 0; }
footer { color: #6b6253; font-size: .85rem; margin-top: 2.5rem; }
@media (prefers-color-scheme: dark) {
  body { color: #ece3d6; background: #1a1713; }
  p, li { color: #d4cabb; }
  .updated, footer { color: #9b917f; }
  a { color: #e0843a; }
  hr { border-top-color: rgba(255,255,255,.12); }
}
"""


def _page(title: str, body: str) -> HTMLResponse:
    html = (
        "<!doctype html><html lang=\"en\"><head>"
        "<meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<meta name=\"robots\" content=\"noindex\">"
        f"<title>{title} · Command</title><style>{_STYLE}</style></head>"
        f"<body><main>{body}"
        f"<footer>© 2026 Legitimate LLC · "
        f"<a href=\"mailto:{_CONTACT}\">{_CONTACT}</a> · "
        "<a href=\"/privacy\">Privacy</a> · <a href=\"/terms\">Terms</a> · "
        "<a href=\"/support\">Support</a></footer>"
        "</main></body></html>"
    )
    return HTMLResponse(html)


@router.get("/privacy", response_class=HTMLResponse)
def privacy() -> HTMLResponse:
    body = f"""
<h1>Command — Privacy Policy</h1>
<p class="updated">Last updated {_UPDATED}</p>

<p>Command is a personal planning app published by <strong>Legitimate LLC</strong>
(&ldquo;we&rdquo;). This policy explains what Command collects, how it is used, and
the choices you have. Questions: <a href="mailto:{_CONTACT}">{_CONTACT}</a>.</p>

<h2>What we collect</h2>
<ul>
  <li><strong>Account</strong> — a username and a securely hashed password (we never
    store your password in readable form).</li>
  <li><strong>Your planning content</strong> — the notes, people, goals, tasks, and
    activity you create in the app. This is the data Command exists to store for you.</li>
  <li><strong>Operational logs</strong> — minimal request logs needed to run and
    secure the service. We do not use advertising or third-party analytics trackers.</li>
</ul>

<h2>Voice transcription</h2>
<p>When you dictate a note, speech-to-text runs <strong>on your device</strong>. The
audio recording is processed locally and is not uploaded to our servers; only the
resulting text is saved as a note, the same as if you had typed it.</p>

<h2>The AI assistant</h2>
<p>Command&rsquo;s optional AI assistant uses third-party large-language-model
providers to answer you. When you send a message to the assistant, the content of
your request and the planning data relevant to it (for example, notes or tasks the
assistant reads to help you) are transmitted to our model router,
<strong>OpenRouter</strong>, and through it to the vendor of the model you picked.
This processing happens only to generate your response.</p>
<ul>
  <li>The model picker decides who receives that text. Today the vendors are
    <strong>Anthropic</strong> (Claude Opus, Sonnet, Haiku), <strong>OpenAI</strong>
    (GPT), <strong>Z.ai</strong> (GLM), and <strong>Moonshot AI</strong> (Kimi). A
    model is sometimes served on its vendor&rsquo;s behalf by a cloud host such as
    Amazon Bedrock, Google Cloud, or Microsoft Azure.</li>
  <li>Untitled notes get a short AI title the same way, using a small model from
    <strong>Alibaba</strong> (Qwen). It sends the beginning of the note and returns a
    two- or three-word title.</li>
  <li>We ask for your <strong>explicit consent</strong> before any of your data is sent
    to a third-party model &mdash; for the assistant and for note titles alike. You can
    decline and still use the rest of the app; notes then keep their first line as the
    title.</li>
  <li>We do <strong>not</strong> sell your data, and we do not use it to train our own
    models. We instruct OpenRouter to route only to providers whose terms state they do
    not train on submitted prompts; providers otherwise process API data under their own
    usage and data policies.</li>
</ul>

<h2>How your data is stored</h2>
<p>Your data lives on a server we operate. Passwords are hashed with bcrypt, traffic
is served over HTTPS, and the assistant is bounded by a per-account monthly usage
limit. No system is perfectly secure, but we take reasonable measures to protect it.</p>

<h2>Sharing</h2>
<p>We share data only with the service providers needed to operate Command (such as
the AI model provider described above, and Apple for subscription billing). We do not
sell your personal information or share it for advertising.</p>

<h2>Retention &amp; deletion</h2>
<p>We keep your content until you delete it or close your account. You can delete most
items in the app, and you can request full account deletion by emailing
<a href="mailto:{_CONTACT}">{_CONTACT}</a>; we will remove your account and its
associated data.</p>

<h2>Children</h2>
<p>Command is not directed to children under 13, and we do not knowingly collect their
data.</p>

<h2>Changes</h2>
<p>We may update this policy; we will revise the date above when we do. Continued use
after a change means you accept the updated policy.</p>

<hr>
<p>Contact: <a href="mailto:{_CONTACT}">{_CONTACT}</a></p>
"""
    return _page("Privacy Policy", body)


@router.get("/terms", response_class=HTMLResponse)
def terms() -> HTMLResponse:
    body = f"""
<h1>Command — Terms of Use</h1>
<p class="updated">Last updated {_UPDATED}</p>

<p>These Terms govern your use of the Command app, published by
<strong>Legitimate LLC</strong>. By creating an account or using the app you agree to
these Terms. If you do not agree, do not use Command.</p>

<h2>License</h2>
<p>We grant you a personal, non-transferable, revocable license to use Command on
Apple devices you own or control, subject to these Terms and to Apple&rsquo;s
<a href="{_APPLE_EULA}">Standard End User License Agreement (EULA)</a>, which is
incorporated here by reference. Where these Terms and the Apple Standard EULA
conflict on the licensed application, the Apple Standard EULA controls.</p>

<h2>Your account</h2>
<p>You are responsible for the activity under your account and for keeping your
credentials and your Command access token secure.</p>

<h2>Command Pro subscription</h2>
<ul>
  <li><strong>Command Pro</strong> unlocks the AI assistant for
    <strong>$19.99 per month</strong>, following a <strong>7-day free trial</strong>
    for new subscribers.</li>
  <li>Payment is charged to your Apple ID at confirmation of purchase. The
    subscription <strong>auto-renews</strong> monthly unless cancelled at least 24
    hours before the end of the current period.</li>
  <li>You can manage or cancel in your device&rsquo;s
    <em>Settings → Apple ID → Subscriptions</em>. If you cancel during the free trial
    before it ends, you will not be charged.</li>
  <li>Subscriptions are billed and refunded by Apple under Apple&rsquo;s terms; we do
    not separately process payments or issue refunds.</li>
</ul>

<h2>Acceptable use</h2>
<p>Do not use Command to break the law, to infringe others&rsquo; rights, or to
attempt to disrupt or gain unauthorized access to the service.</p>

<h2>AI output</h2>
<p>The assistant&rsquo;s responses are generated by AI and may be inaccurate or
incomplete. Use judgment and verify anything important before relying on it. You are
responsible for how you act on the assistant&rsquo;s output.</p>

<h2>No warranty</h2>
<p>Command is provided &ldquo;as is&rdquo; without warranties of any kind, to the
fullest extent permitted by law.</p>

<h2>Limitation of liability</h2>
<p>To the fullest extent permitted by law, Legitimate LLC will not be liable for
indirect, incidental, or consequential damages arising from your use of Command.</p>

<h2>Termination</h2>
<p>You may stop using Command at any time. We may suspend or terminate access for
violations of these Terms.</p>

<h2>Changes</h2>
<p>We may update these Terms; we will revise the date above when we do.</p>

<hr>
<p>Contact: <a href="mailto:{_CONTACT}">{_CONTACT}</a></p>
"""
    return _page("Terms of Use", body)


@router.get("/support", response_class=HTMLResponse)
def support() -> HTMLResponse:
    body = f"""
<h1>Command — Support</h1>
<p class="updated">Last updated {_UPDATED}</p>

<p>Command is a personal planning app — fast capture (calendar + notes, typed or by
voice), a people roster, tasks and goals, and an AI assistant that helps you turn
notes into a plan and delegate it.</p>

<h2>Get help</h2>
<p>Email <a href="mailto:{_CONTACT}">{_CONTACT}</a> with questions, bug reports, or to
request account deletion. We aim to reply within a few business days.</p>

<h2>Subscription</h2>
<p>Manage or cancel <strong>Command Pro</strong> in
<em>Settings → Apple ID → Subscriptions</em> on your device. See the
<a href="/terms">Terms</a> for billing details and the
<a href="/privacy">Privacy Policy</a> for how your data is handled.</p>
"""
    return _page("Support", body)
