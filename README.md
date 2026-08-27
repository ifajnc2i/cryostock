# Cryostock — setup guide

A liquid-nitrogen cell inventory tracker with real per-account login (Supabase Auth)
and an automatic audit log of who changed what. This app is a static site — it talks
directly to your own Supabase project, so your data lives in your Supabase database,
not on Anthropic's infrastructure.

## 1. Create your Supabase project

1. Go to [supabase.com](https://supabase.com) and create a free account / sign in.
2. Click **New project**. Pick a name (e.g. `cryostock`), a strong database password
   (save it somewhere safe — you likely won't need it again), and a region close to
   UCLA (e.g. `us-west-1`).
3. Wait ~2 minutes for the project to finish provisioning.

## 2. Load the database schema

1. In your Supabase project, open **SQL Editor** (left sidebar) → **New query**.
2. Open `schema.sql` from this folder, copy its entire contents, paste it into the
   editor, and click **Run**.
3. This creates all the tables (tanks, racks, boxes, samples, audit log), the
   Row Level Security policies, and the triggers that automatically log every change.

## 3. Lock down sign-up and add lab members

By default Supabase allows anyone to self-register. For a private lab tool, turn
that off:

1. Go to **Authentication → Providers → Email** and turn **off** "Allow new users to
   sign up".

Then add each lab member's account. There are two ways — pick based on whether
you've set up a custom email sender (step 3b below):

**Without custom email (recommended if you don't have your own domain)**: go to
**Authentication → Users → Add user → Create new user**, enter their email, set a
temporary password yourself (e.g. `Cryostock2026!`), and check **Auto Confirm
User**. No email is sent at all — tell them the temporary password directly (in
person, Slack, etc.). Once they log in, they can set their own password from the
**Change password** button in the app's top bar. This avoids Supabase's built-in
email sender entirely, which has a very low rate limit (a couple of emails per
hour) meant only for testing — you'd hit it quickly inviting several people.

**With email invites**: **Authentication → Users → Invite user**, enter their
email — they get a link to set their own password. This needs a custom SMTP
provider configured first (see below) or you'll hit "email rate limit exceeded"
after one or two invites.

Either way, a `profiles` row is created for them automatically (their display name
defaults to the part of their email before `@`; edit it any time in **Table Editor
→ profiles**).

### Optional: configure a custom email sender (for invites / password-reset emails)

Needs a domain you control DNS for. If you have one:

1. Create a free account at [resend.com](https://resend.com) (3,000 emails/month
   free) and add an API key under **API Keys**.
2. Under **Domains**, add your domain and add the SPF/DKIM DNS records Resend
   shows you at your DNS provider. Wait for it to verify.
3. In Supabase: **Authentication → Emails → SMTP Settings**, enable custom SMTP:
   - Host: `smtp.resend.com`, Port: `465`, Username: `resend`, Password: your
     Resend API key
   - Sender email: an address `@` your verified domain (e.g. `noreply@yourdomain.com`)

Without a domain, skip this — the "Add user with password" method above works
just as well for a small lab and needs no email at all.

## 4. Get your API keys

Go to **Project Settings → API**. You need two values:
- **Project URL** (e.g. `https://abcdefgh.supabase.co`)
- **anon / public key** — on newer Supabase projects this is now called the
  **publishable key** and starts with `sb_publishable_...` (older projects show a
  long `eyJ...` JWT instead; both work the same way)

Both are safe to put in client-side code — they only grant what your Row Level
Security policies allow (any logged-in lab member can read/write inventory data;
nobody can read or write anything without logging in first). Never use the
**service_role** key here (newer projects call it the **secret key**,
`sb_secret_...`) — that one bypasses all security and must stay private.

Open `index.html` in this folder, find this block near the top of the `<script>`:

```js
const SUPABASE_URL = "YOUR_SUPABASE_PROJECT_URL";
const SUPABASE_ANON_KEY = "YOUR_SUPABASE_ANON_KEY";
```

Replace both placeholder strings with your actual values, then save.

## 5. Publish it on GitHub Pages

From this `cryostock` folder:

```bash
git init
git add .
git commit -m "Cryostock: liquid nitrogen inventory tracker"
git branch -M main
git remote add origin https://github.com/ifajnc2i/cryostock.git
git push -u origin main
```

(Create the empty repository first at [github.com/new](https://github.com/new) —
name it `cryostock`, and don't add a README/gitignore there since this folder
already has one.)

Then enable Pages: on the repo page, go to **Settings → Pages**, under "Build and
deployment" choose **Deploy from a branch**, branch `main`, folder `/ (root)`, and
save. After a minute or two your app is live at:

```
https://ifajnc2i.github.io/cryostock/
```

Share that URL with your lab. Anyone you've invited in step 3 can log in with their
own email + password; nobody else can even see the login screen do anything useful,
since they have no account.

**A note on privacy**: the repo can be public (it only contains app code — no
research data ever touches GitHub). If you'd rather keep the code itself private,
GitHub Pages for private repos requires a paid GitHub plan; otherwise host the
`index.html` anywhere that serves static files (Netlify, Cloudflare Pages, or even
your own UCLA-hosted web space) — the app works the same everywhere, since all it
needs is to reach your Supabase project over the internet.

## What you get

- **Real accounts**: Supabase Auth handles password hashing/storage properly — not
  a password hidden in the JavaScript, which would be trivially readable by anyone.
- **Audit trail**: every insert/update/delete on tanks, racks, boxes and samples is
  logged automatically by a database trigger (not by the app, so it can't be
  bypassed) — visible in the app's **Activity log** tab.
- **Live sync**: changes from one lab member appear for everyone else within a
  second or two (Supabase Realtime).
- **Mycoplasma status, search, CSV export, box grid view** — same as before.

## Day-to-day maintenance

- Add/remove lab members: **Authentication → Users** in the Supabase dashboard.
- Browse or manually fix data: **Table Editor** in the Supabase dashboard.
- Free tier limits (fine for a small lab): 500MB database, 50k monthly active
  users, project pauses after 1 week with zero API requests (any visit wakes it
  back up within a few seconds).
