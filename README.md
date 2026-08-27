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

## 3. Self-signup with admin approval

Anyone can create their own account from the app's **Sign up** link — but a new
account can't see or touch any inventory data until you approve it. This means you
never have to create accounts by hand, while still controlling exactly who gets in.

1. In Supabase, go to **Authentication → Providers → Email** and turn **off**
   "Confirm email" (so signup doesn't need to send a verification email at all —
   Supabase's built-in email sender has a very low rate limit meant only for
   testing, and you don't need it for this flow).
2. Make yourself the first admin, so you can approve everyone else. Go to
   **SQL Editor → New query**, and run (with your own email):

   ```sql
   update public.profiles set approved = true, is_admin = true
   where id = (select id from auth.users where email = 'YOUR_EMAIL_HERE');
   ```

   (If you don't have an account yet, sign up in the app first, then run this.)

That's it. From now on:
- Anyone visits the app and clicks **Sign up** — name, email, password.
- They land on a "waiting for approval" screen. They can't see any data yet.
- You open the app (as admin), and the **Inventory** tab shows a **Pending
  approval** list at the top with an **Approve** button next to each name.
- The moment you approve someone, they get full access automatically — no need
  for them to sign up again or you to send anything.

You can make additional admins later (people who can also approve accounts) by
running the same SQL update for their email, or by editing the `is_admin` column
directly in **Table Editor → profiles**.

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

Share that URL with your lab. Anyone can sign up, but they stay locked out of the
actual inventory until you approve them from the **Inventory** tab (step 3).

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

- Approve new lab members: the **Pending approval** list at the top of the
  **Inventory** tab (as an admin). To remove someone's access, uncheck `approved`
  for their row in **Table Editor → profiles**, or delete their account entirely
  from **Authentication → Users** in the Supabase dashboard.
- Browse or manually fix data: **Table Editor** in the Supabase dashboard.
- Free tier limits (fine for a small lab): 500MB database, 50k monthly active
  users, project pauses after 1 week with zero API requests (any visit wakes it
  back up within a few seconds).
