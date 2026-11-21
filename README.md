<h1 align="center">Untangle</h1>

<p align="center">
  An open-source podcast player — Flutter and Material 3 Expressive!
</p>

---

## Local configuration

Copy the example file, then fill in only the client-safe Supabase project URL and publishable key in your local `.env`:

```powershell
Copy-Item .env.example .env
# Edit .env locally, then run:
.\scripts\flutter-run-local.ps1
```

The helper passes those values to Flutter through a temporary, ignored build-time configuration file and removes it after the run. `.env` is local-only and is not bundled as an app asset. Never put service-role keys, provider private keys, passwords, or other server-only credentials in `.env` or a Flutter build; keep them in backend environment variables.

---
## Roadmap

🚧 Untangle is a work in progress. If you notice any issues, please <a href="https://github.com/urvakshtirle1946/Untangle/issues" target="_blank" rel="noopener">open an issue</a>.

- [x] Home page 
- [x] Player page 
- [x] Channel page 
- [x] Auth page
- [x] Welcome page
- [x] Onboarding
- [x] Menu page 
- [x] Explore page 
- [x] Downloads page 
- [x] Subscriptions page 
- [ ] Listen history page 
- [ ] Paywall 
- [ ] Empty states of pages
- [ ] Share to social media
- [ ] Feedback page
- [ ] Home widgets 
- [ ] Localization
- [ ] Force update mechanism

---

Untangle is adapted from BunPod by Kamran Bekirov under Apache License 2.0, with the author's written permission. Modifications by Urvaksh Tirle. See [NOTICE](NOTICE), [LICENSE](LICENSE), and [CHANGES.md](CHANGES.md).
