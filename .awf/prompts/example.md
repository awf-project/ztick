# Example Prompt

This is an example prompt file created by AWF.

## Usage

Reference this prompt in workflow inputs using the @prompts/ prefix:

```bash
awf run my-workflow --input prompt=@prompts/example.md
```

## Template Variables

You can use template variables in your workflow commands:

- `{{inputs.prompt}}` - The content of this file

## Tips

- Store reusable AI prompts here (system prompts, task templates)
- Use .md for markdown or .txt for plain text
- Organize complex prompts in subdirectories (e.g., ai/agents/)
