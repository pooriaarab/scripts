# Round 5 drivers

These drivers filed the 17 fleet sites on boards from the browser queue. Read `../README.md`
for the setup and the loop rules. Run one with `python3 ../run.py <driver>`. A driver that sets
`SITES` files only those sites. Run `--dry-run` on one site first.

| Driver | Board | Gate and limit | Needs |
|---|---|---|---|
| `a2adirectory` | a2a.directory | None. The board fetches the agent card and lists the agent at once. | Each site serves `/.well-known/agent-card.json`. |
| `llmslist` | llmslist.com | Stops after about 10 submissions in 10 minutes. | Each site serves `/llms.txt` and `/llms-full.txt`. |
| `llmstxtinfo` | llmstxt.info | Answers "Zu viele Anfragen" after 4 filings in a few minutes. Free Standard tier only. | `/llms.txt`. |
| `huntscreens` | HuntScreens | Magic-link sign-in. The free queue takes about 30 days. The link is nofollow. | Gmail read access (`DIRSUB_MAIL_ACCOUNT`). |
| `collectiveai` | Collective AI Tools | Email and password account. Only the two agent sites fit. | `DIRSUB_ACCOUNTS` file. |
| `curated` | Curated.design | 5 sites a day. One site per visual preset. The $29 lane is never chosen. | None. |
| `minimalgallery` | Minimal Gallery | Selective. Review takes 1-2 weeks. | `DIRSUB_MAKER_NAME`. |
| `researchbuzz` | ResearchBuzz | Contact form for the four sites that are information collections. | `DIRSUB_MAKER_NAME`. |
| `fridayhunt` | FridayHunt | Magic-link sign-in. 6 free slots a week, so launch weeks are spread. The Premium upsell modal is closed. The dashboard is the proof. | Gmail read access, logo. |
| `shipycorn` | Shipycorn | Same template as FridayHunt. Its sign-in mail never arrived on 2026-10-22. | As `fridayhunt`. |
| `stellarlaunch` | Stellar Launch | Email and password account, mail-verified once. 5 slots a day, so launch days are spread. | `DIRSUB_ACCOUNTS`, logo. |
| `saasrow` | SaaSRow | One URL a filing. The management mail is the proof. The page keeps an old draft, so the driver clicks Start Over. | Gmail read access. |
| `sideprojects` | Sideprojects.net | Account made once. On 2026-10-22 every free launch day was full. | `DIRSUB_ACCOUNTS`. |
| `spj` | SPJ Journalist's Toolbox | Anonymous Jotform. Only data sites a reporter could use. | `DIRSUB_MAKER_NAME`, `DIRSUB_COMPANY`. |
| `tipseason` | TipSeason AI Tools | Free queue of 90+ days. Only the two agent sites fit. | None. |
| `cuanschutz` | CU Anschutz library | Library suggestion form for one site. | None. |

Never raise `DriverFail` after the final click. The loop retries a failure, and a retry files the
site twice. A driver returns a `blocked` result when it cannot read a confirmation.

`common.py` holds the fleet order and the topic of each site. A driver maps a topic to the
board's own category.
