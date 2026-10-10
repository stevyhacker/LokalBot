Historical experiment snapshot. Current adoption: **E2B remains the default; the experimental switch enables hybrid plus prefix search.** See [the trial guide](../../../../../../Docs/experimental-autocomplete-hybrid.md). Complete raw evidence and the original, unedited report are in [the experiment archive](../../../2026-10-10-experiments.tar.gz). Archive member paths are listed in [the manifest](../../../2026-10-10-experiments-manifest.json).

---
license: apache-2.0
---

This repo contains YugoGPT - the best open-source base 7B LLM for BCS (Bosnian, Croatian, Serbian) languages developed by Aleksa Gordić.

You can access more powerful iterations of YugoGPT already through the recently announced [RunaAI's API platform](https://dev.runaai.com/)!

Serbian LLM eval results compared to Mistral 7B, LLaMA 2 7B, and GPT2-orao (also see this [LinkedIn post](https://www.linkedin.com/feed/update/urn:li:activity:7143209223722627072/)):
![image/jpeg](https://cdn-uploads.huggingface.co/production/uploads/6169e6f39e1ad4ff8735710b/x_eIAYOIYhI2iPt9s5X9c.jpeg)

Eval was computed using https://github.com/gordicaleksa/serbian-llm-eval

It was trained on tens of billions of BCS tokens and is based off of [Mistral 7B](https://huggingface.co/mistralai/Mistral-7B-v0.1).

## Notes

1) YugoGPT is a base model and therefore does not have any moderation mechanisms.

2) Since it's a base model it won't follow your instructions as it's just a powerful autocomplete engine.

3) If you want an access to much more powerful BCS LLMs (some of which are powering [yugochat](https://www.yugochat.com/)) - you can access the models through [RunaAI's API](https://dev.runaai.com/)

# Credits

The data for the project was obtained with the help of [Nikola Ljubešić](https://nljubesi.github.io/), [CLARIN.SI](https://www.clarin.si), and [CLASSLA](https://www.clarin.si/info/k-centre/). Thank you!

# Project Sponsors

A big thank you to the project sponsors!

## Platinum sponsors 🌟
* <b>Ivan</b> (anon)
* [**Things Solver**](https://thingsolver.com/)

## Gold sponsors 🟡
* **qq** (anon)
* [**Adam  Sofronijevic**](https://www.linkedin.com/in/adam-sofronijevic-685b911/)
* [**Yanado**](https://yanado.com/)
* [**Mitar Perovic**](https://www.linkedin.com/in/perovicmitar/)
* [**Nikola Ivancevic**](https://www.linkedin.com/in/nivancevic/)
* **Rational Development DOO**
* [**Ivan**](https://www.linkedin.com/in/ivan-kokic-258262175/) i [**Natalija Kokić**](https://www.linkedin.com/in/natalija-kokic-19a458131/)

## Silver sponsors ⚪
[**psk.rs**](https://psk.rs/), [**OmniStreak**](https://omnistreak.com/), [**Luka Važić**](https://www.linkedin.com/in/vazic/), [**Miloš Durković**](https://www.linkedin.com/in/milo%C5%A1-d-684b99188/), [**Marjan Radeski**](https://www.linkedin.com/in/marjanradeski/), **Marjan Stankovic**, [**Nikola Stojiljkovic**](https://www.linkedin.com/in/nikola-stojiljkovic-10469239/), [**Mihailo Tomić**](https://www.linkedin.com/in/mihailotomic/), [**Bojan Jevtic**](https://www.linkedin.com/in/bojanjevtic/), [**Jelena Jovanović**](https://www.linkedin.com/in/eldumo/), [**Nenad Davidović**](https://www.linkedin.com/in/nenad-davidovic-662ab749/), [**Mika Tasich**](https://www.linkedin.com/in/mikatasich/), [**TRENCH-NS**](https://www.linkedin.com/in/milorad-vukadinovic-64639926/), [**Nemanja Grujičić**](https://twitter.com/nemanjagrujicic), [**tim011**](https://knjigovodja.in.rs/sh)

**Also a big thank you to the following individuals:**
- [**Slobodan Marković**](https://www.linkedin.com/in/smarkovic/) - for spreading the word! :)
- [**Aleksander Segedi**](https://www.linkedin.com/in/aleksander-segedi-08430936/) - for help around bookkeeping!

## Citation

```
@article{YugoGPT,
  author    = "Gordić Aleksa",
  title     = "YugoGPT - an open-source LLM for Serbian, Bosnian, and Croatian languages",
  year      = "2024"
  howpublished = {\url{https://huggingface.co/gordicaleksa/YugoGPT}},
}
```
