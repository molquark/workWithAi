package com.example.architecture; // TODO 改成你们测试模块自己的包名

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;
import com.tngtech.archunit.library.freeze.FreezingArchRule;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

/**
 * 把「团队约定」编译成「构建失败」。
 *
 * <p>为什么要有这个类：文档会被忽略，报错不会。AI（和人）看到一条红色失败信息，
 * 会立刻改；看到一份 README，会跳过。所以凡是能用规则表达的约定，都应该写在这里，
 * 而不是写在文档里。
 *
 * <p>包名一律用 ArchUnit 的 {@code ..} 通配符写，好处是不用关心你们的代码到底在
 * {@code com.example.module.xxx} 还是 {@code com.example.biz.xxx} 下面：
 * <ul>
 *   <li>{@code ..controller..} 匹配任意深度下含 {@code controller} 段的包</li>
 *   <li>所以 {@code biz.order.util} 和 {@code service.common.util} 都会被 {@code ..util..} 命中</li>
 * </ul>
 *
 * <p><b>存量违规怎么办：</b>用 {@code FreezingArchRule.freeze(rule)} 包一层。
 * 它会把当前所有违规记录到 {@code src/test/resources/archunit_store/}，
 * 之后只对**新增**违规失败。这样你不用先还清技术债，也能立刻止损。
 */
@AnalyzeClasses(
        // TODO 改成你们的基础包，例如 "com.example"
        packages = "com.example",
        importOptions = ImportOption.DoNotIncludeTests.class)
class ConventionRules {

    /**
     * 规则 1：Controller 层禁止直接使用 Spring 的 ResponseEntity。
     *
     * <p>这是「统一返回体」从口头约定变成硬约束的那一步。AI 特别爱写 ResponseEntity，
     * 因为它在开源代码里见得最多；光在提示词里说「用我们的 Result」压不住。
     */
    @ArchTest
    static final ArchRule controllers_must_not_use_response_entity =
            noClasses()
                    .that().resideInAPackage("..controller..")
                    .should().dependOnClassesThat()
                    .haveFullyQualifiedName("org.springframework.http.ResponseEntity");

    /**
     * 规则 2：只有 UserHolder 自己能碰 SecurityContextHolder。
     *
     * <p>{@code UserHolder} 是 ThreadLocal，在调用图里完全不可见——AI 看不到它，
     * 也推不出来。这条规则的作用不是「防 AI」，是让「获取当前用户」这件事只有一个入口。
     * TODO 把 "..holder.." 换成你们 UserHolder 实际所在的包。
     */
    @ArchTest
    static final ArchRule only_user_holder_touches_security_context =
            noClasses()
                    .that().resideOutsideOfPackages("..holder..", "..security..", "..config..")
                    .should().dependOnClassesThat()
                    .haveFullyQualifiedName("org.springframework.security.core.context.SecurityContextHolder");

    /**
     * 规则 3：工具类必须落在 util / common 包里。
     *
     * <p>你们现在的工具类是散的（biz 下的 util、各 service 模块里都有），
     * 所以这条规则**一定会先挂一片**——所以用 FreezingArchRule 冻结存量。
     * 效果是：老代码不动，但从此以后新建的工具类不许乱放。
     *
     * <p>副作用是好的：工具类都聚到 util 包以后，docs/UTILITIES.md 才有意义，
     * AI 才可能「先查再写」。
     */
    @ArchTest
    static final ArchRule utils_live_in_util_packages =
            FreezingArchRule.freeze(
                    classes()
                            .that().haveSimpleNameEndingWith("Util")
                            .or().haveSimpleNameEndingWith("Utils")
                            .or().haveSimpleNameEndingWith("Helper")
                            .should().resideInAnyPackage("..util..", "..utils..", "..common.."));

    /**
     * 规则 4：Controller 不许越过 Service 直接摸 Mapper / DAO。
     *
     * <p>AI 最容易犯的错之一：为了「少写一个方法」，直接在 Controller 里注入 Mapper。
     * 代码能跑，分层就烂了。
     */
    @ArchTest
    static final ArchRule controllers_do_not_touch_components =
            noClasses()
                    .that().resideInAPackage("..controller..")
                    .should().dependOnClassesThat()
                    .resideInAnyPackage("..mapper..", "..dao..", "..repository..");

    // 需要更多规则时照这个模板加。两个常用的：
    //
    // @ArchTest
    // static final ArchRule services_must_not_depend_on_controllers =
    //         noClasses().that().resideInAPackage("..service..")
    //                 .should().dependOnClassesThat().resideInAPackage("..controller..");
    //
    // 想让某条规则「只报告不阻塞」（先观察一周再转成强制），把它换成一个普通测试方法：
    //
    // @Test
    // void reportResponseEntityUsages() {
    //     controllers_must_not_use_response_entity.allowEmptyShould(true)
    //             .check(importPackages("com.example"));
    // }
}
