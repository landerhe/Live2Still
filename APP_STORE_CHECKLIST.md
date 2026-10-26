# App Store Connect checklist (outside the Xcode project)

Complete these in App Store Connect before submitting. The binary now includes privacy manifest, encryption flag, iPhone-only targeting, and in-app Privacy / About / Support.

## 1. Host public pages

You still need publicly reachable URLs for Connect (GitHub Pages, Notion, or your site):

- **Privacy Policy URL** — mirror the in-app policy in `LivePhotoAboutViews.swift` (on-device Photos processing, no upload, no tracking, contact email).
- **Support URL** — a page or `mailto:` that actually works. Update `LivePhotoSupportLinks` in `LivePhotoAboutViews.swift` to match.

Suggested placeholders currently in code:

- Privacy: `https://live2still.app/privacy`
- Support: `mailto:support@live2still.app`

地址与邮箱按用户 2026-10-04 的要求暂不修改；在最后的上架准备阶段确认所有权、公开可访问性与收信能力。

## 2. App information

- Name (≤30): e.g. `Live2Still`
- Subtitle (≤30): e.g. `Live Photos to stills`
- Category: **Photo & Video** (secondary optional: Utilities)
- Content rights / copyright: `© 2026 LH`
- Age rating questionnaire (Photos access → usually 4+)
- Uncheck **iPhone apps on Mac** / Designed for iPad Mac availability unless you tested there

## 3. App Privacy (nutrition labels)

Declare **Data Not Collected** if you still ship with no analytics, ads, accounts, or uploads.

Keep the public privacy policy consistent with that declaration and with on-device Photo Library use.

## 4. Screenshots (iPhone only)

Required size sets for the devices you select (typically 6.9" and 6.3"). Capture on a physical device or Simulator **without** Simulator chrome in the frame:

1. Permission / welcome
2. Album with selection + Convert / Remove original visible
3. Convert success toast
4. Swipe card with Still / Keep / Delete
5. Queue sheet with Apply

Do not show developer-only copy.

## 5. Description draft (edit freely)

**Description**

Live2Still saves still copies of the current appearance of your Live Photos, with a batch review workflow in your photo library.

• Browse Live Photos in Album and convert the ones you choose  
• Swipe to queue stills or deletes, then Apply when ready  
• Optionally remove the original Live Photo after conversion  
• Works offline with photos stored on this device  
• Processing stays on your iPhone; cloud photos may download through Apple iCloud Photos

Requires iOS 26.

**Keywords** (comma-separated, ≤100 chars)

live photo,still,storage,convert,clean,library,photos,free space

**What’s New (1.0)**

First release: batch Live Photo conversion, persistent review queues, verified copies, and optional original removal.

## 6. Review notes

Paste something like:

```
Demo steps:
1. Open Camera → enable Live → take one Live Photo.
2. Open Live2Still → allow Photos access (Limited or Full both work).
3. Choose Keep Originals on first use. Album: select the photo → Convert. Review Last Conversion from Settings.
4. Swipe tab: swipe left = still, right = keep, down = delete; Undo is in the toolbar; open Queue → Apply.

No account. No network required except for iCloud-only photos.
Privacy Policy and Support are in Settings (…) → About, and on the permission screen footer.
```

## 7. Export compliance

Binary sets `ITSAppUsesNonExemptEncryption = NO`. In Connect, confirm the app only uses standard HTTPS / OS encryption if asked.

## 8. Final device QA

Run `scripts/qa-verification.sh` on a physical iPhone with dedicated Live Photo copies before archive.

2026-10-04 修复验证：队列保存、Keep/Undo、统一操作锁、分块转换、当前外观导出、元数据验证、取消和结果恢复已加入代码。具体通过与未通过的测试以 `REPAIR_STATUS.md` 为准。

必须完成：编辑／关键照片／iCloud 样本，有限及撤销权限，低磁盘空间，转换中退出／强制终止，VoiceOver 与大字号。仅使用专用测试副本进行删除验证。Recently Deleted 与 iCloud 同步期间不要宣称立即释放固定容量。
