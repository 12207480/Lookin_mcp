# Lookin MCP

这是一个 MCP server，用于让支持 MCP 的客户端读取 Lookin 导出的 `.lookin` 文件，也可以通过更新后的 Lookin App 本地 bridge 实时读取当前连接 App，并执行少量受限写操作。

文件模式会直接解析 `.lookin` 文件里的 NSKeyedArchive。实时模式通过 Lookin App 内置的 `127.0.0.1:47638` HTTP bridge 拉取当前连接 App 的 hierarchy snapshot，再复用同一套解析逻辑。

## 能力

- `lookin_inspect_file`：查看 `.lookin` 文件的概要、对象数量和主要 archive class。
- `lookin_list_hierarchy`：分页列出 UI 层级。
- `lookin_search_hierarchy`：按类名、标题、subtitle、对象 id、内存地址或已解码字段搜索。
- `lookin_get_item`：按列表 id、对象 oid 或内存地址查看单个节点详情。
- `lookin_live_status`：查看 Lookin App 本地 bridge 是否可用、当前是否有连接 App。
- `lookin_live_inspect_current`：实时拉取当前连接 App 并查看概要。
- `lookin_live_list_hierarchy`：实时拉取当前连接 App 并分页列出 UI 层级。
- `lookin_live_search_hierarchy`：实时拉取当前连接 App 并搜索 UI 层级。
- `lookin_live_get_item`：实时拉取当前连接 App 并查看单节点详情。
- `lookin_live_capture_current_layer_screenshot`：截取 Lookin 当前选中层的截图并保存为本地 TIFF 文件。
- `lookin_live_invoke_method`：对当前选中对象或指定 oid 调用无参方法/属性。
- `lookin_live_set_selected_frame`：修改 Lookin 当前选中层的 `frame`。
- `lookin_live_set_view_property`：修改当前选中 view/layer 的常用属性，覆盖 UIView、UILabel、UIButton、UIImageView、UIScrollView、UITableView、UICollectionView、UITableViewCell、UICollectionViewCell、UITextView、UITextField 等基础控件。
- `lookin_live_set_constraint_property`：按显式 NSLayoutConstraint oid 修改 `constant` / `priority` / `active`。

除截图文件写出和两个 `lookin_live_*` 写工具外，其余工具都是只读操作。

## 客户端配置

以本仓库路径为例：

```json
{
  "mcpServers": {
    "lookin": {
      "command": "python3",
      "args": ["/Users/yeb/Documents/Lookin/mcp/lookin_mcp.py"]
    }
  }
}
```

如果仓库路径不同，把 `args` 里的脚本路径改成实际路径。

## 使用方式

### 读取导出文件

1. 在 Lookin App 中连接目标 iOS App。
2. 通过 Lookin 的导出能力保存 `.lookin` 文件。
3. 在 MCP 客户端中调用工具，例如：

```json
{
  "path": "/Users/yeb/Desktop/MyApp_ios17_05161230.lookin",
  "query": "UIButton",
  "limit": 20
}
```

### 实时读取当前连接 App

1. 启动包含 `LKMCPBridgeServer` 的 Lookin App。
2. 在 Lookin App 中连接目标 iOS App。
3. 在 MCP 客户端中调用：

```json
{
  "query": "UIButton",
  "limit": 20,
  "refresh": true
}
```

`refresh: true` 会让 Lookin App 重新执行一次 `fetchHierarchyData`；`refresh: false` 只读取 Lookin 当前缓存的 hierarchy。

截取当前选中层截图：

```json
{
  "image_type": "auto",
  "output_path": "/private/tmp/lookin_current_layer.tiff"
}
```

`image_type` 支持：

- `auto`：沿用 Lookin 预览逻辑，展开节点优先取 `soloScreenshot`，否则取 `groupScreenshot`。
- `group`：取当前层和子层组合截图。
- `solo`：只取当前层截图。

### 受限写操作

调用当前选中 view 的无参方法：

```json
{
  "method": "setNeedsLayout",
  "target": "selected_view"
}
```

`target` 支持：

- `selected_view` / `view`
- `selected_layer` / `layer`
- `selected_controller` / `controller`

也可以传 `oid` 直接指定 Lookin 对象，此时会忽略 `target`：

```json
{
  "oid": 123456,
  "method": "setNeedsDisplay"
}
```

修改当前选中层的 frame：

```json
{
  "x": 0,
  "y": 0,
  "width": 100,
  "height": 44
}
```

修改常用 view 属性：

```json
{
  "property": "text",
  "value": "Hello"
}
```

```json
{
  "property": "textColor",
  "value": "#FF3366"
}
```

```json
{
  "property": "contentEdgeInsets",
  "value": {
    "top": 8,
    "left": 12,
    "bottom": 8,
    "right": 12
  }
}
```

常用属性别名：

- 基础 view/layer：`frame`、`bounds`、`hidden`、`alpha`、`backgroundColor`、`cornerRadius`、`borderColor`、`borderWidth`、`contentMode`、`tintColor`、`tag`
- AutoLayout priority：`huggingHorizontal`、`huggingVertical`、`compressionResistanceHorizontal`、`compressionResistanceVertical`
- UILabel：`text`、`numberOfLines`、`fontSize`、`textColor`、`textAlignment`、`lineBreakMode`、`adjustsFontSizeToFitWidth`
- UIButton / UIControl：`enabled`、`selected`、`contentVerticalAlignment`、`contentHorizontalAlignment`、`contentEdgeInsets`、`titleEdgeInsets`、`imageEdgeInsets`
- UIImageView：复用基础 view/layer 属性，如 `contentMode`、`tintColor`、`hidden`、`alpha`、`backgroundColor`
- UIScrollView / UICollectionView：`contentOffset`、`contentSize`、`contentInset`、`qmuiInitialContentInset`、`contentInsetAdjustmentBehavior`、`scrollIndicatorInsets`、`scrollEnabled`、`pagingEnabled`、`alwaysBounceVertical`、`alwaysBounceHorizontal`、`showsHorizontalScrollIndicator`、`showsVerticalScrollIndicator`、`delaysContentTouches`、`canCancelContentTouches`、`minimumZoomScale`、`maximumZoomScale`、`zoomScale`、`bouncesZoom`
- UITableView：除 UIScrollView 属性外，额外支持 `separatorInset`、`separatorColor`、`separatorStyle`
- UITableViewCell / UICollectionViewCell：继承基础 view/layer 属性，额外支持 `highlighted`、`cellSelected`；UITableViewCell 额外支持 `selectionStyle`、`accessoryType`、`editing`
- UITextView：`textViewText`、`textViewFontSize`、`textViewTextColor`、`textViewTextAlignment`、`editable`、`selectable`、`textContainerInset`
- UITextField：`textFieldText`、`placeholder`、`textFieldFontSize`、`textFieldTextColor`、`textFieldTextAlignment`、`clearsOnBeginEditing`、`clearsOnInsertion`、`minimumFontSize`

颜色值支持 `#RRGGBB`、`#RRGGBBAA`、`[r, g, b, a]` 或 `{ "r": 255, "g": 0, "b": 0, "a": 1 }`。Rect 使用 `{ "x": 0, "y": 0, "width": 100, "height": 44 }`，Insets 使用 `{ "top": 0, "left": 0, "bottom": 0, "right": 0 }`。

修改约束对象属性：

```json
{
  "oid": 123456,
  "property": "constant",
  "value": 12
}
```

`lookin_live_set_constraint_property` 需要传显式 `NSLayoutConstraint` 对象 oid。当前 Lookin 的约束展示模型只展示约束描述，没有稳定暴露 constraint oid，因此 MCP 不能仅凭“当前选中 view 的第几个约束”可靠修改；view 自身的 AutoLayout priority 可用上面的 `hugging*` / `compressionResistance*` 属性修改。

## 写操作边界

- 只开放受限写入口：`POST /invoke-method`、`POST /selected-frame`、`POST /set-property`、`POST /set-constraint-property`。
- `lookin_live_invoke_method` 只支持无参 selector 或属性名，不支持带 `:` 的方法。
- `lookin_live_set_selected_frame` 只修改当前选中层的 `frame`。
- `lookin_live_set_view_property` 只支持内置白名单属性，不开放任意 selector。
- `lookin_live_set_constraint_property` 只支持显式 constraint oid 的 `constant`、`priority`、`active`。
- 写操作依赖当前 Lookin 已连接 App，并会通过 Lookin 原有 `invokeMethodWithOid:` / `submitInbuiltModification:` 链路转发到目标 App。

## 设计边界

- App 内 bridge 只绑定 `127.0.0.1:47638`，不监听外部网络。
- 实时模式开放 `GET /status`、`GET /snapshot`、`GET /selected-screenshot` 和受限 POST 写入口。
- 除截图工具会按用户传入路径写出 TIFF 文件外，不写回 `.lookin` 文件。
- 不依赖第三方 Python 包，便于本地直接运行。
