# Lookin MCP

这是一个只读 MCP server，用于让支持 MCP 的客户端读取 Lookin 导出的 `.lookin` 文件，也可以通过更新后的 Lookin App 本地 bridge 实时读取当前连接 App。

文件模式会直接解析 `.lookin` 文件里的 NSKeyedArchive。实时模式通过 Lookin App 内置的 `127.0.0.1:47638` 只读 HTTP bridge 拉取当前连接 App 的 hierarchy snapshot，再复用同一套解析逻辑。

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

所有工具都是只读操作。

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

## 设计边界

- App 内 bridge 只绑定 `127.0.0.1:47638`，不监听外部网络。
- 实时模式只开放 `GET /status`、`GET /snapshot` 和 `GET /selected-screenshot`。
- 不修改目标 iOS App，也不调用 Lookin 的属性修改接口。
- 除截图工具会按用户传入路径写出 TIFF 文件外，不写回 `.lookin` 文件。
- 不依赖第三方 Python 包，便于本地直接运行。

后续如果要支持属性修改或方法调用，建议单独设计权限和确认机制，不要复用当前只读 bridge。
