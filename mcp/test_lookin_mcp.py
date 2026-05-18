import unittest

import lookin_mcp


class LookinMCPTests(unittest.TestCase):
    def test_tools_list_exposes_optimized_live_tools(self):
        response = lookin_mcp.handle_request(
            {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        )

        tools = response["result"]["tools"]
        tool_names = {tool["name"] for tool in tools}
        self.assertIn("lookin_live_get_selected_item", tool_names)
        self.assertIn("lookin_live_list_writable_properties", tool_names)

    def test_invoke_method_schema_is_allowlisted(self):
        tools = {tool["name"]: tool for tool in lookin_mcp.tool_definitions()}
        method_schema = tools["lookin_live_invoke_method"]["inputSchema"]["properties"]["method"]

        self.assertIn("setNeedsLayout", method_schema["enum"])
        self.assertNotIn("removeFromSuperview", method_schema["enum"])

    def test_invoke_method_rejects_unsupported_selector_before_bridge_call(self):
        with self.assertRaisesRegex(lookin_mcp.ToolError, "Unsupported method"):
            lookin_mcp.tool_live_invoke_method({"method": "removeFromSuperview"})

    def test_bridge_url_requires_localhost(self):
        with self.assertRaisesRegex(lookin_mcp.ToolError, "localhost"):
            lookin_mcp.bridge_url({"bridge_url": "http://192.168.0.2:47638"})

    def test_writable_properties_include_common_views(self):
        payload = lookin_mcp.tool_live_list_writable_properties({"response_format": "json"})
        data = lookin_mcp.json.loads(payload)

        self.assertIn("contentOffset", data["property_groups"]["scroll_view"])
        self.assertIn("separatorStyle", data["property_groups"]["table_view"])
        self.assertIn("cellSelected", data["property_groups"]["cell"])


if __name__ == "__main__":
    unittest.main()
