# Copyright 2019 OpenAPI-Generator-Bazel Contributors

def _comma_separated_pairs(pairs):
    return ",".join([
        "{}={}".format(k, v)
        for k, v in pairs.items()
    ])

def _new_generator_command(ctx, declared_dir, rjars):
    java_path = ctx.attr._jdk[java_common.JavaRuntimeInfo].java_executable_exec_path
    gen_cmd = str(java_path)

    jar_delimiter = ":"
    if ctx.attr.is_windows:
        jar_delimiter = ";"

    jars = [ctx.file.openapi_generator_cli] + rjars.to_list()

    gen_cmd += " -cp \"{jars}\" org.openapitools.codegen.OpenAPIGenerator generate -i {spec} -g {generator} -o {output}".format(
        java = java_path,
        jars = jar_delimiter.join([j.path for j in jars]),
        spec = ctx.file.spec.path,
        generator = ctx.attr.generator,
        output = declared_dir.path,
    )

    gen_cmd += ' -p "{properties}"'.format(
        properties = _comma_separated_pairs(ctx.attr.system_properties),
    )

    additional_properties = dict(ctx.attr.additional_properties)

    # This is needed to ensure reproducible Java output
    if ctx.attr.generator == "java" and \
       "hideGenerationTimestamp" not in ctx.attr.additional_properties:
        additional_properties["hideGenerationTimestamp"] = "true"

    gen_cmd += ' --additional-properties "{properties}"'.format(
        properties = _comma_separated_pairs(additional_properties),
    )

    gen_cmd += ' --type-mappings "{mappings}"'.format(
        mappings = _comma_separated_pairs(ctx.attr.type_mappings),
    )

    gen_cmd += ' --reserved-words-mappings "{reserved_words_mappings}"'.format(
        reserved_words_mappings = ",".join(ctx.attr.reserved_words_mappings),
    )

    if ctx.attr.config:
        gen_cmd += " --config {config}".format(
            config = ctx.attr.config.files.to_list()[0].path,
        )
    if ctx.attr.template_dir:
        gen_cmd += " --template-dir {template_dir}".format(
            template_dir = ctx.attr.template_dir.files.to_list()[0].path,
        )

    if ctx.attr.api_package:
        gen_cmd += " --api-package {package}".format(
            package = ctx.attr.api_package,
        )
    if ctx.attr.invoker_package:
        gen_cmd += " --invoker-package {package}".format(
            package = ctx.attr.invoker_package,
        )
    if ctx.attr.model_package:
        gen_cmd += " --model-package {package}".format(
            package = ctx.attr.model_package,
        )
    if ctx.attr.engine:
        gen_cmd += " --engine {package}".format(
            package = ctx.attr.engine,
        )

    gen_cmd += " --skip-validate-spec"

    # fixme: by default, openapi-generator is rather verbose. this helps with that but can also mask useful error messages
    # when it fails. look into log configuration options. it's a java app so perhaps just a log4j.properties or something
    gen_cmd += " 1>/dev/null"
    return gen_cmd

def _impl(ctx):
    jars = _collect_jars(ctx.attr.deps)
    (cjars, rjars) = (jars.compiletime, jars.runtime)

    declared_dir = ctx.actions.declare_directory("%s" % (ctx.attr.name))

    inputs = [
        ctx.file.openapi_generator_cli,
        ctx.file.spec,
    ] + cjars.to_list() + rjars.to_list()

    if ctx.attr.config:
        inputs += ctx.attr.config.files.to_list()

    if ctx.attr.template_dir:
        inputs += ctx.attr.template_dir.files.to_list()

    # TODO: Convert to run
    ctx.actions.run_shell(
        inputs = inputs,
        command = "mkdir -p {gen_dir} && {generator_command}".format(
            gen_dir = declared_dir.path,
            generator_command = _new_generator_command(ctx, declared_dir, rjars),
        ),
        outputs = [declared_dir],
        tools = ctx.files._jdk,
        toolchain = ctx.attr._jdk.label,
    )

    srcs = declared_dir.path

    return DefaultInfo(files = depset([
        declared_dir,
    ]))

# taken from rules_scala
def _collect_jars(targets):
    """Compute the runtime and compile-time dependencies from the given targets"""  # noqa
    compile_jars = depset()
    runtime_jars = depset()
    for target in targets:
        found = False
        if hasattr(target, "scala"):
            if hasattr(target.scala.outputs, "ijar"):
                compile_jars = depset(transitive = [compile_jars, [target.scala.outputs.ijar]])
            compile_jars = depset(transitive = [compile_jars, target.scala.transitive_compile_exports])
            runtime_jars = depset(transitive = [runtime_jars, target.scala.transitive_runtime_deps])
            runtime_jars = depset(transitive = [runtime_jars, target.scala.transitive_runtime_exports])
            found = True
        if hasattr(target, "JavaInfo"):
            # see JavaSkylarkApiProvider.java,
            # this is just the compile-time deps
            # this should be improved in bazel 0.1.5 to get outputs.ijar
            # compile_jars = depset(transitive = [compile_jars, [target.java.outputs.ijar]])
            compile_jars = depset(transitive = [compile_jars, target[JavaInfo].transitive_deps])
            runtime_jars = depset(transitive = [runtime_jars, target[JavaInfo].transitive_runtime_deps])
            found = True
        if not found:
            # support http_file pointed at a jar. http_jar uses ijar,
            # which breaks scala macros
            runtime_jars = depset(transitive = [runtime_jars, target.files])
            compile_jars = depset(transitive = [compile_jars, target.files])

    return struct(compiletime = compile_jars, runtime = runtime_jars)

_openapi_generator = rule(
    attrs = {
        # downstream dependencies
        "deps": attr.label_list(allow_files = True),
        # openapi spec file
        "spec": attr.label(
            mandatory = True,
            allow_single_file = [
                ".json",
                ".yaml",
                ".yml",
            ],
        ),
        "template_dir": attr.label(allow_single_file = True),
        "config": attr.label(allow_single_file = True),
        "generator": attr.string(mandatory = True),
        "api_package": attr.string(),
        "invoker_package": attr.string(),
        "model_package": attr.string(),
        "additional_properties": attr.string_dict(),
        "system_properties": attr.string_dict(),
        "engine": attr.string(),
        "type_mappings": attr.string_dict(),
        "reserved_words_mappings": attr.string_list(),
        "is_windows": attr.bool(mandatory = True),
        "_jdk": attr.label(
            default = Label("@bazel_tools//tools/jdk:current_host_java_runtime"),
            providers = [java_common.JavaRuntimeInfo],
        ),
        "openapi_generator_cli": attr.label(
            cfg = "exec",
            default = Label("@openapi_tools_generator_bazel_cli//:openapi_tools_generator_bazel_cli"),
            allow_single_file = True,
        ),
    },
    implementation = _impl,
)

def openapi_generator(name, **kwargs):
    _openapi_generator(
        name = name,
        is_windows = select({
            "@bazel_tools//src/conditions:windows": True,
            "//conditions:default": False,
        }),
        **kwargs
    )
