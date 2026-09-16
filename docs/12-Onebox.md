# 链接渲染（onebox）

帖子正文里的裸 URL `https://站点/collections/:id` 由 core 的 local onebox 机制在**烘焙期**渲染：**独占一行**时替换为专辑卡片，**位于句中**时把链接正文替换为「专辑名 - 淘专辑」。本插件不为此新增任何端点。

## 1. 触发条件与守卫

- 命中路由 `GET /collections/:id`（02 的路由总表），且 `:id` 为数字；其余 `/collections/...` 路径（如 `mine` / `invites`）不渲染。

- 加类由 core 的 markdown-it onebox 特性完成：仅**自动链接**（`linkify` + `auto`）、**独占整行**且以 `http` / `//` 开头时，给 `<a>` 加 `onebox` 类走卡片通路；同类链接**位于句中**时走 inline 通路。`[文字](url)` 与相对路径两条通路都不触发。

- 三道守卫，任一不成立即不渲染：

  | 守卫 | 判据 |
  | -- | -- |
  | `collection_enabled` | 关闭 → 卡片与 inline 一并抑制 |
  | `collection_onebox_enabled` | 默认关闭；关闭 → 一并抑制 |
  | `collection_onebox_disabled_categories` | 命中的话题分类 → 一并抑制 |

- 分类闸取**该帖所在话题的分类**（烘焙时由 core 作为选项传入），不是专辑自身属性；帖不属任何话题（无分类）时不抑制。

- 专辑不存在时不渲染。core 随即回退为普通链接并**替换掉** `a.onebox`，客户端不会再补渲染。

## 2. 卡片内容

卡片只含专辑级公开信息：名称、描述、`topic_count`、`subscriber_count`、共同维护者数、owner（头像 + 用户名）、`created_at`、`last_topic_added_at`。

- **不含**话题标题与摘要。
- **不含**逐访问者信息。卡片烘焙一次后写进 `posts.cooked`，对所有读者（含游客）是同一份产物，故列表卡上的 role 章（owner / 共同维护者，见 03 的 1）在卡片里没有对应物。

计数口径：共同维护者数 = `collection_teamworkers` 中 `is_owner = false` 的行数（实体无此冗余列）；`subscriber_count` 取 `collections.subscribers_count`（口径见 08 的 1）。

占位：无 owner → 「无主」；`last_topic_added_at` 为 NULL → 「暂无话题」。

文案一律在服务端取 `discourse_collection.onebox.*`（server locale），与前端同名卡片文案各存一份。

## 3. 卡片结构

```html
<aside class="onebox collection-onebox">
  <div class="collection-onebox__body">            <!-- 窄屏纵向堆叠，≥768px 走两列网格 -->
    <div class="collection-onebox__main">
      <h3 class="collection-onebox__name"><a href="{帖子里的原始 URL}">{专辑图标}{专辑名}</a></h3>
      <p class="collection-onebox__description">…</p>   <!-- 描述为空则整块不渲染 -->
    </div>
    <div class="collection-onebox__meta">
      <div class="collection-onebox__owner">
        <a class="collection-onebox__owner-link" data-user-card="{username}">
          <img class="avatar" width="24" height="24" src="{头像}">
          <span class="collection-onebox__owner-name">{username}</span>
        </a>   <!-- 无 owner 时改为 .-unclaimed 的「无主」span -->
      </div>
      <div class="collection-onebox__stats">
        <span class="collection-onebox__stat">…</span> ×3   <!-- 话题数 / 订阅数 / 共同维护者数 -->
      </div>
    </div>
    <div class="collection-onebox__times">
      <span class="collection-onebox__activity">…</span> ×2   <!-- 创建 / 最近收录；各含 .collection-onebox__date[data-time]，见 5；无收录时第二枚为 .-none 占位 -->
    </div>
  </div>
</aside>
```

- 专辑名前是插件自带的 sprite 图标 `collection`（`svg-icons/collection.svg`，随站点 sprite bundle 下发，无需 `register_asset`），与专辑名同处一个链接，故随名称一起可点。
- 头像与用户名同处一个 `<a>`（单一锚点），且该 `<a>` 不吃整卡点击。
- owner 的 `<a>` **不带 `href`**：core 的链接点击统计监听挂在话题元素上（比 `#main-outlet` 上的用户卡监听更靠内），带 `href` 的锚点会在卡片弹出后被它路由走。跳转只由专辑名一条链接提供。
- 头像请求尺寸固定 **48**、渲染尺寸固定 **24**。`/user_avatar/…/:size/…` 只服务 `SiteSetting.avatar_sizes`（默认 `24|48|72|96|144|288`）列出的尺寸，且较小的那些不一定可得（`User#small_avatar_url` 取的 45 即不在其列）。
- 卡片本身不再用 `<a>` 包裹（`a` 不能嵌 `a`）：链接只给专辑名。
- 窄屏与列表卡 `collection-tile` 同构；≥768px 网格把 owner 与统计挪到右侧、时间行左右分列。

## 4. inline 标题

位于句中的链接，其正文被替换为 `%{name} - 淘专辑`（en 为 `%{name} - Collections`），键 `discourse_collection.onebox.inline_title`。core 对该标题做 HTML 转义。

## 5. 时间

两个时间在烘焙期写进 `span.collection-onebox__date[data-time="{毫秒}"]` 的正文，正文是**绝对日期加 UTC 标记**（`I18n.l(…, format: :long)` 套 `discourse_collection.onebox.utc_time`）。服务端只有 UTC 一个时区，不写明会被邮件与摘要读者当成自己的本地时间。故邮件、摘要与无 JS 读者看到的是带标记的 UTC 时刻。

浏览器侧由插件自带的 initializer（`assets/javascripts/discourse/initializers/collection-onebox-dates.js`）改写：按 `data-time` 算距离，**5 天内**给 core 的相对文案，**超过 5 天**给读者本地时区的完整时刻（`longDate`），并每 60s 重算一次（跨过 5 天边界时由这次重算接手）。

不用 core 的 `.relative-date`，是因为它的 `medium` 格式过了 5 天固定落到短日期，没有哪个 format 能留住完整时刻；元素上留着 `relative-date` 类则会让 core 的 ticker 与插件各写各的。

装饰在 cooked 元素**进入文档之前**执行（`d-decorated-html.gjs` 先 `applyHtmlDecorators` 再 `adoptNode`），所以烘焙文本不会在页面上闪出。`data-time` 是绝对毫秒，故重算只换显示时区，不改变时刻本身。

卡片冻结在烘焙时刻：专辑改名或删除后，已烘焙帖子里的卡片不变（与核心话题 onebox 同）。

## 6. 落点与运维

- 落点：`lib/discourse_collection/onebox_handler.rb`、模板 `lib/discourse_collection/onebox/templates/collection.mustache`、`lib/discourse_collection/onebox_opts_forwarding.rb`；注册在 `plugin.rb` 的 `after_initialize`。

- 两个 dispatcher 的注册键是**路由的 controller 名**：本 engine `isolate_namespace`，故键为 `discourse_collection/collections`。键写错只表现为静默失效。

- core 不把烘焙选项传给已注册的 handler（分类闸所需的 `category_id` 即在其中），故 prepend `Oneboxer.local_onebox` 与 `InlineOneboxer.lookup`，在调用期间把选项暂存于当前线程，handler 侧读回。

- **存量帖需重新烘焙**才会长出卡片：这些 URL 此前已被 core 的兜底 `<a>` 顶掉 `a.onebox`，客户端补渲染不会发生。卡片自身的改动同理（如 5 的时间元素从 `relative-date` 改名为 `collection-onebox__date`）：旧帖的 cooked 里仍是旧形态，装饰器选择器认不到，得重新烘焙才会走新逻辑。

- 无 DB 改动。
