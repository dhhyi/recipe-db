from pathlib import Path

from ansible.errors import AnsibleFilterError


def _resolve_operator_path(value, config_directory, direct_directory=None):
    if not isinstance(value, str) or not value or any(ord(char) < 32 for char in value):
        raise AnsibleFilterError("private config reference is missing or invalid")
    try:
        reference = Path(value)
        root = Path(config_directory).resolve(strict=True)
        candidate = reference if reference.is_absolute() else root / reference
        resolved = candidate.resolve()
        if not reference.is_absolute() and not resolved.is_relative_to(root):
            raise AnsibleFilterError("relative private config reference escapes its root")
        if direct_directory is not None:
            allowed = (root / direct_directory).resolve(strict=True)
            if not allowed.is_relative_to(root) or candidate.parent != root / direct_directory \
                    or resolved.parent != allowed or candidate.is_symlink():
                raise AnsibleFilterError("private application input must be a direct deployment file")
        resolved = candidate.resolve(strict=True)
        if not resolved.is_file():
            raise AnsibleFilterError("private config reference is not a regular file")
    except AnsibleFilterError:
        raise
    except (OSError, RuntimeError, ValueError) as error:
        raise AnsibleFilterError("private config reference is missing or invalid") from error
    return str(resolved)


class FilterModule:
    def filters(self):
        return {
            "operator_config_path": _resolve_operator_path,
            "operator_deployment_file": lambda value, config_directory:
                _resolve_operator_path(value, config_directory, "deployment"),
        }
