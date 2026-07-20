# Partner plugin doc submission

## Samples

Sample output: [https://developer.konghq.com/plugins/prisma-airs-intercept/](https://developer.konghq.com/plugins/prisma-airs-intercept/)  
Sample source files: [https://github.com/Kong/developer.konghq.com/tree/main/app/\_kong\_plugins/prisma-airs-intercept](https://github.com/Kong/developer.konghq.com/tree/main/app/_kong_plugins/prisma-airs-intercept)

## Required collateral

- Logo icon in PNG or SVG format, 64x64px  
- Plugin schema in JSON format. For example: [https://github.com/Kong/developer.konghq.com/blob/main/app/\_kong\_plugins/prisma-airs-intercept/schema.json](https://github.com/Kong/developer.konghq.com/blob/main/app/_kong_plugins/prisma-airs-intercept/schema.json)  
- Link to or name of luarock

## Doc template

### Introduction

Introduce your plugin with a long description.
What does it do, and why would someone want to use it?

For example:

*Use the Mocking plugin to provide mock endpoints to test your APIs in development against your services.*  
*The plugin leverages standards based on the Open API Specification (OAS)*  
*for sending out mock responses to APIs. Mocking supports both Swagger 2.0 and OpenAPI 3.0.*

*Benefits of service mocking with the Kong Mocking plugin:*

- *Conforms to a design-first approach since mock responses are within OAS.*  
- *Accelerates development of services and APIs.*

### How it works

How does your plugin work? What entities does it interact with? What output does it produce?

For example:

*When you enable this plugin, it adds a new header to all of the requests processed by Kong Gateway. This header bears the name configured in the `config.header_name` variable, and a unique value is generated according to `config.generator`.*

*This header is always added in calls to your upstream services, and optionally echoed back to your clients according to the `config.echo_downstream` setting.*

*If a header with the same name is already present in the client request, the plugin honors it and does **not** tamper with it.*

### Installation details

Luarock name or link: `kong-plugin-examplename`  
If your plugin isn’t publicly available on Luarocks, provide info on how to get the plugin files. For example:

*Obtain the plugin directly from Example Company or a distributor.*

If your plugin can’t be installed via a rock file or similar, provide instructions on how to install it.

### Example configuration

Include any prerequisites that a user might need before using this plugin:

- Do they need an access token from your application?  
- Maybe they need a specific application type?  
- Or they need to configure something in their application admin console or dashboard to allow access by this plugin?

Then, provide a sample plugin config in yaml or curl format, and explain what the config is doing.
For example:

*In the following example, the Rate Limiting plugin allows 200 requests per 30 minutes, resetting exactly on the 30 minute mark with no carryover of unused limits.*

```
plugins:
  - name: rate-limiting
    config:
      limit:
        - 200
      window_size:
        - 1800
      window_type: fixed
```

Or, if your plugin doesn’t have any config parameters, or you just want users to enable it, you can simply provide that information:

*Enable the ExamplePlugin plugin.*

```
plugins:
  - name: example-plugin
```
